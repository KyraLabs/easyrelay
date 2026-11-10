const std = @import("std");
const easyrelay = @import("easyrelay");
const nostr = @import("nostr");

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

    pub fn start(gpa: std.mem.Allocator, limits: easyrelay.session.Limits) !*Relay {
        const self = try gpa.create(Relay);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{}),
            .events = undefined,
            .connections = undefined,
            .writer = undefined,
            .shared = undefined,
            .app = undefined,
            .server = undefined,
            .listener = undefined,
        };

        const relay_io = self.threaded.io();
        errdefer self.threaded.deinit();
        self.events = easyrelay.memory.Memory.init(gpa, relay_io);
        errdefer self.events.deinit();
        self.connections = easyrelay.hub.Hub.init(gpa, relay_io);
        errdefer self.connections.deinit();
        self.writer = try easyrelay.writer.Writer.init(gpa, relay_io, self.events.store(), &self.connections, 64);
        errdefer self.writer.deinit();
        try self.writer.start();
        errdefer self.writer.stop();
        self.shared = .{
            .io = relay_io,
            .store = self.events.store(),
            .hub = &self.connections,
            .writer = &self.writer,
            .limits = limits,
        };
        self.app = .{ .gpa = gpa, .shared = &self.shared };
        self.server = try easyrelay.server.init(gpa, &self.app, .{ .port = 0 });
        errdefer self.server.deinit();
        self.listener = try self.server.listenInNewThread();
        return self;
    }

    pub fn io(self: *Relay) std.Io {
        return self.threaded.io();
    }

    pub fn port(self: *Relay) u16 {
        return self.server.address.getPort();
    }

    pub fn stop(self: *Relay) void {
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
};

pub const Client = struct {
    arena: std.heap.ArenaAllocator,
    socket: *easyrelay.client.Client,

    pub fn connect(relay: *Relay) !Client {
        const socket = try easyrelay.client.Client.connect(relay.gpa, relay.io(), relay.port(), 2000);
        return .{ .arena = std.heap.ArenaAllocator.init(relay.gpa), .socket = socket };
    }

    pub fn close(self: *Client) void {
        self.socket.close();
        self.arena.deinit();
    }

    pub fn allocator(self: *Client) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn send(self: *Client, message: []const u8) !void {
        try self.socket.send(message);
    }

    pub fn sendEvent(self: *Client, event: nostr.event.Event) !void {
        try self.send(try nostr.message.encodeEvent(self.allocator(), event));
    }

    pub fn receive(self: *Client) ![]const u8 {
        return self.allocator().dupe(u8, try self.socket.receive());
    }

    pub fn receiveJson(self: *Client) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator(), try self.receive(), .{});
    }

    /// Fails if anything arrives within `window_ms`.
    pub fn expectSilence(self: *Client, window_ms: u32) !void {
        try self.socket.setTimeout(window_ms);
        defer self.socket.setTimeout(2000) catch {};
        const unexpected = self.socket.receive() catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
        std.debug.print("expected silence, received: {s}\n", .{unexpected});
        return error.UnexpectedMessage;
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
