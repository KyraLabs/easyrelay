const std = @import("std");
const nostr = @import("nostr");
const ws = @import("websocket");

const hub = @import("../relay/hub.zig");
const session = @import("../relay/session.zig");
const subscriptions = @import("../relay/subscriptions.zig");

const log = std.log.scoped(.server);

pub const Server = ws.Server(Connection);

pub const App = struct {
    gpa: std.mem.Allocator,
    shared: *const session.Shared,
    live: std.atomic.Value(usize) = .init(0),
};

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    max_connections: usize = 1024,
    handshake_timeout_ms: u32 = 5000,
    max_message_size: usize = 131072,
    message_threads: ?u16 = null,
};

pub fn init(gpa: std.mem.Allocator, app: *App, options: Options) !Server {
    return Server.init(app.shared.io, gpa, .{
        .address = options.address,
        .port = options.port,
        .max_conn = options.max_connections,
        .max_message_size = options.max_message_size,
        .handshake = .{
            .timeout = @intCast(@min(
                (@as(u64, options.handshake_timeout_ms) + 999) / 1000,
                std.math.maxInt(u32),
            )),
            .max_headers = 0,
        },
        .thread_pool = .{ .count = options.message_threads },
    });
}

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
    subscriber: hub.Subscriber,
    /// websocket.zig may call `close` twice.
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(handshake: *ws.Handshake, conn: *ws.Conn, app: *App) !Connection {
        _ = handshake;
        _ = app.live.fetchAdd(1, .monotonic);
        return .{
            .app = app,
            .conn = conn,
            .subscriber = .{
                .registry = subscriptions.Registry.init(app.gpa, app.shared.limits.subscription),
                .delivery = undefined,
            },
        };
    }

    pub fn afterInit(self: *Connection) !void {
        self.subscriber.delivery = .{ .ptr = self, .sendFn = deliver };
        try self.app.shared.hub.join(&self.subscriber);
    }

    pub fn close(self: *Connection) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Leave the hub before freeing: a broadcast may be reading this connection.
        self.app.shared.hub.leave(&self.subscriber);
        self.subscriber.registry.deinit();
        _ = self.app.live.fetchSub(1, .release);
    }

    fn deliver(ptr: *anyopaque, message: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ptr));
        self.conn.write(message) catch |err| {
            log.debug("dropping a delivery to a closed connection: {t}", .{err});
        };
    }

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
        defer {
            frame.deinit();
            self.frame = null;
        }
        frame.send() catch return error.WriteFailed;
    }
};

const testing = std.testing;
const memory = @import("../storage/memory.zig");

const test_port = 47_777;

fn drain(io: std.Io, app: *App) !void {
    for (0..200) |_| {
        if (app.live.load(.acquire) == 0) return;
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

    var backing = memory.Memory.init(testing.allocator, testing.io);
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

    // `Client.write` masks the payload in place.
    const message = try arena.dupe(u8, try nostr.message.encodeEvent(arena, event));
    try client.write(message);

    try client.readTimeout(2000);
    const reply = (try client.read()) orelse return error.RelayDidNotAnswer;
    defer client.done(reply);

    const id = std.fmt.bytesToHex(event.id, .lower);
    const expected = try std.fmt.allocPrint(arena, "[\"OK\",\"{s}\",true,\"\"]", .{id});
    try testing.expectEqualStrings(expected, reply.data);

    try client.close(.{});
    try drain(io, &app);
}

test "one connection subscribes, another publishes, and the first receives it live" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var backing = memory.Memory.init(testing.allocator, testing.io);
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
    try drain(io, &app);
}
