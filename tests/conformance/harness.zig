const std = @import("std");
const easyrelay = @import("easyrelay");
const nostr = @import("nostr");
const ws = @import("websocket");

var next_port: std.atomic.Value(u16) = .init(47_800);

pub const Relay = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    events: easyrelay.memory.Memory,
    connections: easyrelay.hub.Hub,
    writer: easyrelay.writer.Writer,
    shared: easyrelay.session.Shared,
    app: easyrelay.server.App,
    server: easyrelay.server.Server,
    listener: std.Thread,
    port: u16,

    pub fn start(gpa: std.mem.Allocator, limits: easyrelay.session.Limits) !*Relay {
        const self = try gpa.create(Relay);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{}),
            .events = undefined,
            .port = next_port.fetchAdd(1, .monotonic),
            .connections = undefined,
            .writer = undefined,
            .shared = undefined,
            .app = undefined,
            .server = undefined,
            .listener = undefined,
        };

        const relay_io = self.threaded.io();
        self.events = easyrelay.memory.Memory.init(gpa, relay_io);
        self.connections = easyrelay.hub.Hub.init(gpa, relay_io);
        self.writer = try easyrelay.writer.Writer.init(gpa, relay_io, self.events.store(), &self.connections, 64);
        try self.writer.start();
        self.shared = .{
            .io = relay_io,
            .store = self.events.store(),
            .hub = &self.connections,
            .writer = &self.writer,
            .limits = limits,
        };
        self.app = .{ .gpa = gpa, .shared = &self.shared };
        self.server = try easyrelay.server.init(gpa, &self.app, .{
            .port = self.port,
            .message_threads = 2,
        });
        self.listener = try self.server.listenInNewThread(&self.app);
        return self;
    }

    pub fn io(self: *Relay) std.Io {
        return self.threaded.io();
    }

    /// Stopping before every connection closes hits a transport shutdown race.
    pub fn stop(self: *Relay) void {
        self.drain() catch {};
        self.server.stop();
        self.listener.join();
        self.server.deinit();
        self.writer.stop();
        self.writer.deinit();
        self.connections.deinit();
        self.events.deinit();
        self.threaded.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn drain(self: *Relay) !void {
        for (0..200) |_| {
            if (self.app.live.load(.acquire) == 0) return;
            try self.io().sleep(.fromMilliseconds(10), .awake);
        }
        return error.ConnectionsDidNotClose;
    }
};

pub const Client = struct {
    arena: std.heap.ArenaAllocator,
    socket: ws.Client,

    pub fn connect(relay: *Relay) !Client {
        var socket = try ws.Client.init(relay.io(), relay.gpa, .{
            .port = relay.port,
            .host = "127.0.0.1",
        });
        errdefer socket.deinit();
        try socket.handshake("/", .{ .timeout_ms = 2000, .headers = "Host: 127.0.0.1" });
        try socket.readTimeout(2000);
        return .{ .arena = std.heap.ArenaAllocator.init(relay.gpa), .socket = socket };
    }

    pub fn close(self: *Client) void {
        self.socket.close(.{}) catch {};
        self.socket.deinit();
        self.arena.deinit();
    }

    pub fn allocator(self: *Client) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// `Client.write` masks the payload in place.
    pub fn send(self: *Client, message: []const u8) !void {
        try self.socket.write(try self.allocator().dupe(u8, message));
    }

    pub fn sendEvent(self: *Client, event: nostr.event.Event) !void {
        try self.send(try nostr.message.encodeEvent(self.allocator(), event));
    }

    pub fn receive(self: *Client) ![]const u8 {
        const message = (try self.socket.read()) orelse return error.RelayDidNotAnswer;
        defer self.socket.done(message);
        return self.allocator().dupe(u8, message.data);
    }

    pub fn receiveJson(self: *Client) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator(), try self.receive(), .{});
    }

    pub fn expectSilence(self: *Client, window_ms: u32) !void {
        try self.socket.readTimeout(window_ms);
        defer self.socket.readTimeout(2000) catch {};
        if (try self.socket.read()) |unexpected| {
            defer self.socket.done(unexpected);
            std.debug.print("expected silence, received: {s}\n", .{unexpected.data});
            return error.RelayAnsweredWhenItShouldNot;
        }
    }
};

pub const Author = struct {
    signer: nostr.keys.Signer,
    keypair: nostr.keys.KeyPair,

    pub fn init(secret_byte: u8) !Author {
        const signer = nostr.keys.Signer.init();
        return .{ .signer = signer, .keypair = try signer.keyPairFromSecretKey([_]u8{secret_byte} ** 32) };
    }

    pub fn deinit(self: *Author) void {
        self.signer.deinit();
    }

    pub fn event(
        self: Author,
        arena: std.mem.Allocator,
        created_at: i64,
        kind: u16,
        tags: []const nostr.event.Tag,
        content: []const u8,
    ) !nostr.event.Event {
        return nostr.event.create(arena, self.signer, self.keypair, created_at, kind, tags, content, null);
    }

    pub fn pubkeyHex(self: Author) [64]u8 {
        return std.fmt.bytesToHex(self.keypair.public_key, .lower);
    }
};

pub const event_time: i64 = 1_700_000_000;
