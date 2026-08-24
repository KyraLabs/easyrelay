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

const session = @import("../relay/session.zig");

/// The transport, parameterised by this relay's connection handler.
pub const Server = ws.Server(Connection);

/// Shared by every connection. `io` is here because the wall clock comes
/// through it in Zig 0.16 and each message needs one reading of it.
pub const App = struct {
    io: std.Io,
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
    return Server.init(app.io, gpa, .{
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

    pub fn init(handshake: *ws.Handshake, conn: *ws.Conn, app: *App) !Connection {
        // Nothing in the handshake decides anything yet. NIP-42 and the
        // admission policy are Phase 3, and they arrive here.
        _ = handshake;
        return .{ .app = app, .conn = conn };
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
        };
        try current.handle(.{
            .arena = arena,
            .signer = signer(),
            .now = std.Io.Timestamp.now(self.app.io, .real).toSeconds(),
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

test "a client publishes over a real connection and is answered OK" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backing = memory.Memory.init(testing.allocator);
    defer backing.deinit();
    const shared: session.Shared = .{ .store = backing.store() };
    var app: App = .{ .io = io, .shared = &shared };

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
}
