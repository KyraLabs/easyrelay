//! What the conformance tests run against: a real relay on a real socket, and
//! a real client to drive it.
//!
//! docs/testing.md asks for exactly this. A conformance test that called into
//! the relay's own functions would check easyrelay against easyrelay; these
//! check it against a client that knows only the wire.

const std = @import("std");
const easyrelay = @import("easyrelay");
const nostr = @import("nostr");
const ws = @import("websocket");

/// Each relay takes the next port. The transport binds inside `listen` and
/// never reports which port it got, so this cannot be zero — and every relay
/// getting its own keeps a stopping one out of a starting one's way.
var next_port: std.atomic.Value(u16) = .init(47_800);

pub const Relay = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    events: easyrelay.memory.Memory,
    connections: easyrelay.hub.Hub,
    shared: easyrelay.session.Shared,
    app: easyrelay.server.App,
    server: easyrelay.server.Server,
    listener: std.Thread,
    port: u16,

    /// Heap-allocated because the relay points at its own fields.
    pub fn start(gpa: std.mem.Allocator, limits: easyrelay.session.Limits) !*Relay {
        const self = try gpa.create(Relay);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{}),
            .events = easyrelay.memory.Memory.init(gpa),
            .port = next_port.fetchAdd(1, .monotonic),
            .connections = undefined,
            .shared = undefined,
            .app = undefined,
            .server = undefined,
            .listener = undefined,
        };

        const relay_io = self.threaded.io();
        self.connections = easyrelay.hub.Hub.init(gpa, relay_io);
        self.shared = .{
            .io = relay_io,
            .store = self.events.store(),
            .hub = &self.connections,
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

    /// Stops once every connection has finished closing. Stopping earlier
    /// walks into the shutdown race recorded in
    /// docs/adr/0004-websocket-transport.md.
    pub fn stop(self: *Relay) void {
        self.drain() catch {};
        self.server.stop();
        self.listener.join();
        self.server.deinit();
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

    /// `Client.write` masks the payload in the caller's buffer, so everything
    /// sent gets its own copy. Phase 0 found this the hard way.
    pub fn send(self: *Client, message: []const u8) !void {
        try self.socket.write(try self.allocator().dupe(u8, message));
    }

    pub fn sendEvent(self: *Client, event: nostr.event.Event) !void {
        try self.send(try nostr.message.encodeEvent(self.allocator(), event));
    }

    /// The next message, copied out of the library's buffer so it stays valid
    /// for the rest of the test.
    pub fn receive(self: *Client) ![]const u8 {
        const message = (try self.socket.read()) orelse return error.RelayDidNotAnswer;
        defer self.socket.done(message);
        return self.allocator().dupe(u8, message.data);
    }

    /// The next message as its JSON array, for asserting on a field rather
    /// than on a spelling.
    pub fn receiveJson(self: *Client) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator(), try self.receive(), .{});
    }

    /// Fails if anything arrives within `window_ms`.
    ///
    /// The window is the whole assertion: without one, a test cannot tell
    /// "nothing" from "not yet". It is deliberately short, because this is
    /// waiting for something that must not happen and every test that calls it
    /// pays the full wait.
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

/// Signs events, so that a test can put a real event on the wire without
/// keeping a fixture of one.
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

/// Unix seconds the conformance tests date their events with. Fixed, so that
/// no assertion depends on when the suite runs, and in the past, because the
/// relay refuses an event claiming to be from the future while accepting any
/// age by default (docs/protocol.md#structural-limits).
pub const event_time: i64 = 1_700_000_000;
