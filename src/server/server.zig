//! The transport: sockets, frames, and nothing else.
//!
//! It owns a `websocket.zig` server, turns each connection into a
//! `relay.Session`, and gives that session a `Responder` that writes real
//! WebSocket frames. Everything about *what* the relay answers lives a layer
//! down; this file is about how the bytes get there
//! (docs/architecture.md#transport).

const std = @import("std");
const nostr = @import("nostr");
const ws = @import("websocket");

const hub = @import("../relay/hub.zig");
const session = @import("../relay/session.zig");
const subscriptions = @import("../relay/subscriptions.zig");

const log = std.log.scoped(.server);

/// The transport, parameterised by this relay's connection handler.
pub const Server = ws.Server(Connection);

/// Shared by every connection. `io` is here because the wall clock comes
/// through it in Zig 0.16 and each message needs one reading of it.
pub const App = struct {
    /// For connection-lifetime state. Never an arena: a connection's
    /// subscriptions come and go, and memory a client can make grow without
    /// bound is a memory it can exhaust.
    gpa: std.mem.Allocator,
    shared: *const session.Shared,
};

/// Mirrors the `network` section of docs/configuration.md, spelling included,
/// so Phase 2's configuration file maps onto it without a translation table.
pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    max_connections: usize = 1024,
    handshake_timeout_ms: u32 = 5000,
    /// docs/protocol.md's message limit. A message over it closes the
    /// connection rather than being answered: there is nothing to answer with
    /// when the relay never saw the end of it.
    max_message_size: usize = 131072,
    /// Threads that run message handling. Null lets the library size the pool.
    message_threads: ?u16 = null,
};

pub fn init(gpa: std.mem.Allocator, app: *App, options: Options) !Server {
    return Server.init(app.shared.io, gpa, .{
        .address = options.address,
        .port = options.port,
        .max_conn = options.max_connections,
        .max_message_size = options.max_message_size,
        .handshake = .{
            // The library counts the handshake timeout in whole seconds while
            // docs/configuration.md publishes milliseconds. Round up, so that a
            // configured timeout is never shorter than what was asked for.
            .timeout = @intCast((options.handshake_timeout_ms + 999) / 1000),
            .max_headers = 0,
        },
        .thread_pool = .{ .count = options.message_threads },
    });
}

/// One `keys.Signer` for each thread of the message pool.
///
/// `keys.Signer` documents itself as not thread-safe for concurrent use of one
/// instance, which Phase 0 caught before it could become a race. The pool owns
/// its threads and outlives every connection, so the context is created on
/// first use and released by the process exiting — which is also why this is a
/// thread-local rather than something with an owner.
threadlocal var thread_signer: ?nostr.keys.Signer = null;

fn signer() nostr.keys.Signer {
    if (thread_signer) |existing| return existing;
    const created = nostr.keys.Signer.init();
    thread_signer = created;
    return created;
}

pub const Connection = struct {
    app: *App,
    conn: *ws.Conn,
    /// This connection's subscriptions and the way back to its socket.
    subscriber: hub.Subscriber,
    /// `websocket.zig` can call `close` twice on one connection: its cleanup
    /// path releases the per-connection lock *before* calling the handler's
    /// `close`, while its shutdown path calls it *holding* that lock, so a
    /// client disconnecting as the server stops can reach both. Freeing this
    /// connection's subscriptions twice is a double free, which is what the
    /// testing allocator caught. An exchange makes the second call a no-op.
    /// See docs/adr/0004-websocket-transport.md.
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(handshake: *ws.Handshake, conn: *ws.Conn, app: *App) !Connection {
        // Nothing in the handshake decides anything yet. NIP-42 and the
        // admission policy are Phase 3, and they arrive here.
        _ = handshake;
        return .{
            .app = app,
            .conn = conn,
            .subscriber = .{
                .registry = subscriptions.Registry.init(app.gpa, app.shared.limits.subscription),
                // Filled in by `afterInit`, which is the first time this
                // connection knows the address it will keep: the handler is
                // returned by value here and moved into place afterwards.
                .delivery = undefined,
            },
        };
    }

    /// Called once the handshake response is out, with the handler at its final
    /// address. Registering before that would publish a pointer to a value that
    /// is about to move.
    pub fn afterInit(self: *Connection) !void {
        self.subscriber.delivery = .{ .ptr = self, .sendFn = deliver };
        try self.app.shared.hub.join(&self.subscriber);
    }

    /// Called exactly once, whatever ends the connection, including a
    /// connection that never finished starting.
    pub fn close(self: *Connection) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Leaving first: the hub holds its own lock for the whole of a
        // broadcast, so once this returns no publisher is reading what the
        // next line frees.
        self.app.shared.hub.leave(&self.subscriber);
        self.subscriber.registry.deinit();
    }

    /// Called from other connections' threads. `websocket.zig` documents
    /// `Conn.write` as safe to call concurrently, which is what makes fan-out
    /// possible without a queue of our own.
    fn deliver(ptr: *anyopaque, message: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ptr));
        self.conn.write(message) catch |err| {
            // The connection is finished; the transport will notice and run
            // `close`. Saying so is the operator's only view of it until
            // Phase 3 adds metrics.
            log.debug("dropping a delivery to a closed connection: {t}", .{err});
        };
    }

    /// `websocket.zig` guarantees one message at a time per connection, so
    /// nothing here needs a lock. `arena` is its per-message allocator: a
    /// thread-local buffer falling back to an arena, released when this
    /// returns, which is exactly the per-request arena the relay wants.
    pub fn clientMessage(self: *Connection, arena: std.mem.Allocator, data: []u8) !void {
        var frames: FrameResponder = .{ .conn = self.conn, .arena = arena };
        var current: session.Session = .{
            .shared = self.app.shared,
            .responder = frames.responder(),
            .subscriber = &self.subscriber,
        };
        try current.handle(.{
            .arena = arena,
            .signer = signer(),
            .now = std.Io.Timestamp.now(self.app.shared.io, .real).toSeconds(),
        }, data);
    }
};

/// A `session.Responder` over real frames: one `begin`/`send` pair is one
/// WebSocket message.
const FrameResponder = struct {
    conn: *ws.Conn,
    arena: std.mem.Allocator,
    frame: ?ws.Conn.Writer = null,

    const vtable: session.Responder.VTable = .{ .begin = begin, .send = send };

    fn responder(self: *FrameResponder) session.Responder {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn begin(ptr: *anyopaque) std.Io.Writer.Error!*std.Io.Writer {
        const self: *FrameResponder = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.frame == null);
        self.frame = self.conn.writeBuffer(self.arena, .text);
        return &self.frame.?.interface;
    }

    fn send(ptr: *anyopaque) std.Io.Writer.Error!void {
        const self: *FrameResponder = @ptrCast(@alignCast(ptr));
        var frame = &(self.frame orelse return error.WriteFailed);
        // Released before the next frame is begun rather than at the end of
        // the message: a `REQ` answered with five hundred events must not hold
        // five hundred buffers, which is the same rule the store's streaming
        // sink exists for.
        defer {
            frame.deinit();
            self.frame = null;
        }
        frame.send() catch return error.WriteFailed;
    }
};

const testing = std.testing;
const memory = @import("../storage/memory.zig");

/// A port high enough to be out of the way. The library binds inside `listen`
/// and does not report back which port it got, so this cannot be zero.
const test_port = 47_777;

/// Waits until the relay has seen every connection go.
///
/// Stopping while a connection is still being torn down walks into a race in
/// `websocket.zig`: one thread frees a connection's state while a pool thread
/// is still running that connection's `close`. Draining first keeps the test
/// out of that window, and it is what Phase 3's graceful shutdown will do for
/// real — stop accepting, let the connections finish, then close.
fn drain(io: std.Io, connections: *hub.Hub) !void {
    for (0..200) |_| {
        if (connections.count() == 0) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ConnectionsDidNotClose;
}

test "a client publishes over a real connection and is answered OK" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backing = memory.Memory.init(testing.allocator);
    defer backing.deinit();
    var connections = hub.Hub.init(testing.allocator, io);
    defer connections.deinit();

    const shared: session.Shared = .{ .io = io, .store = backing.store(), .hub = &connections };
    var app: App = .{ .gpa = testing.allocator, .shared = &shared };

    var server = try init(testing.allocator, &app, .{
        .port = test_port,
        .message_threads = 1,
    });
    defer server.deinit();

    const listener = try server.listenInNewThread(&app);
    defer listener.join();
    defer server.stop();

    var client = try ws.Client.init(io, testing.allocator, .{
        .port = test_port,
        .host = "127.0.0.1",
    });
    defer client.deinit();
    try client.handshake("/", .{ .timeout_ms = 2000, .headers = "Host: 127.0.0.1" });

    var signer_instance = nostr.keys.Signer.init();
    defer signer_instance.deinit();
    const keypair = try signer_instance.keyPairFromSecretKey([_]u8{5} ** 32);
    const event = try nostr.event.create(
        arena,
        signer_instance,
        keypair,
        std.Io.Timestamp.now(io, .real).toSeconds(),
        1,
        &.{},
        "over the wire",
        null,
    );

    // `Client.write` masks the payload in place, mutating the caller's buffer.
    // Phase 0 found this; anything that needs the bytes afterwards copies first.
    const message = try arena.dupe(u8, try nostr.message.encodeEvent(arena, event));
    try client.write(message);

    try client.readTimeout(2000);
    const reply = (try client.read()) orelse return error.RelayDidNotAnswer;
    defer client.done(reply);

    const id = std.fmt.bytesToHex(event.id, .lower);
    const expected = try std.fmt.allocPrint(arena, "[\"OK\",\"{s}\",true,\"\"]", .{id});
    try testing.expectEqualStrings(expected, reply.data);

    try client.close(.{});
    try drain(io, &connections);
}

test "one connection subscribes, another publishes, and the first receives it live" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backing = memory.Memory.init(testing.allocator);
    defer backing.deinit();
    var connections = hub.Hub.init(testing.allocator, io);
    defer connections.deinit();

    const shared: session.Shared = .{ .io = io, .store = backing.store(), .hub = &connections };
    var app: App = .{ .gpa = testing.allocator, .shared = &shared };

    var server = try init(testing.allocator, &app, .{
        .port = test_port + 1,
        .message_threads = 2,
    });
    defer server.deinit();

    const listener = try server.listenInNewThread(&app);
    defer listener.join();
    defer server.stop();

    var reader = try ws.Client.init(io, testing.allocator, .{
        .port = test_port + 1,
        .host = "127.0.0.1",
    });
    defer reader.deinit();
    try reader.handshake("/", .{ .timeout_ms = 2000, .headers = "Host: 127.0.0.1" });
    try reader.readTimeout(2000);

    // The subscription is open once its `EOSE` has arrived, which is what makes
    // everything after this a live delivery rather than a stored one.
    try reader.write(try arena.dupe(u8, "[\"REQ\",\"live\",{\"kinds\":[1]}]"));
    {
        const eose = (try reader.read()) orelse return error.RelayDidNotAnswer;
        defer reader.done(eose);
        try testing.expectEqualStrings("[\"EOSE\",\"live\"]", eose.data);
    }

    var writer = try ws.Client.init(io, testing.allocator, .{
        .port = test_port + 1,
        .host = "127.0.0.1",
    });
    defer writer.deinit();
    try writer.handshake("/", .{ .timeout_ms = 2000, .headers = "Host: 127.0.0.1" });
    try writer.readTimeout(2000);

    var signer_instance = nostr.keys.Signer.init();
    defer signer_instance.deinit();
    const keypair = try signer_instance.keyPairFromSecretKey([_]u8{6} ** 32);
    const event = try nostr.event.create(
        arena,
        signer_instance,
        keypair,
        std.Io.Timestamp.now(io, .real).toSeconds(),
        1,
        &.{},
        "over two connections",
        null,
    );
    try writer.write(try arena.dupe(u8, try nostr.message.encodeEvent(arena, event)));
    {
        const ok = (try writer.read()) orelse return error.RelayDidNotAnswer;
        defer writer.done(ok);
        try testing.expect(std.mem.indexOf(u8, ok.data, ",true,\"\"]") != null);
    }

    const delivered = (try reader.read()) orelse return error.NothingWasDelivered;
    defer reader.done(delivered);
    try testing.expect(std.mem.startsWith(u8, delivered.data, "[\"EVENT\",\"live\","));
    try testing.expect(std.mem.indexOf(u8, delivered.data, "over two connections") != null);

    try reader.close(.{});
    try writer.close(.{});
    try drain(io, &connections);
}
