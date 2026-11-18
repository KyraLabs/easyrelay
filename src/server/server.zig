const std = @import("std");
const nostr = @import("nostr");

const frame = @import("../transport/frame.zig");
const handshake = @import("../transport/handshake.zig");
const Outbox = @import("outbox.zig").Outbox;
const listener = @import("../transport/listener.zig");
const socket = @import("../transport/socket.zig");
const hub = @import("../relay/hub.zig");
const nip11 = @import("../relay/nip11.zig");
const rate = @import("../relay/rate.zig");
const metrics = @import("../relay/metrics.zig");
const session = @import("../relay/session.zig");
const subscriptions = @import("../relay/subscriptions.zig");

const log = std.log.scoped(.server);

pub const App = struct {
    gpa: std.mem.Allocator,
    shared: *const session.Shared,
    live: std.atomic.Value(usize) = .init(0),
    information: ?*const nip11.Responses = null,
    /// Per-connection budgets; null leaves connections unlimited.
    rates: ?rate.Limits = null,
    metrics: ?*metrics.Metrics = null,
    /// Where `GET` serves the metrics; null serves none.
    metrics_path: ?[]const u8 = null,
};

/// Above this the store is reported unhealthy: a write may no longer fit.
const healthy_map_ratio = 0.95;

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    max_connections: usize = 1024,
    handshake_timeout_ms: u32 = 5000,
    max_message_size: usize = 131072,
    write_buffer_limit: usize = 1024 * 1024,
    write_timeout_ms: u32 = 30_000,
    /// Ping a connection after this long without hearing from it; zero never pings.
    ping_interval_ms: u32 = 30_000,
    /// Close a connection after this long without hearing from it; zero never does.
    idle_timeout_ms: u32 = 300_000,
};

const thread_stack_size = 4 * 1024 * 1024;
/// glibc carves static TLS out of each thread's stack, and std's per-thread signal stack alone is 256 KiB.
const sender_stack_size = 1024 * 1024;
/// A sender batch that grew past this is freed after writing, so an idle connection holds little.
const retained_batch_capacity = 64 * 1024;
const service_unavailable = "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";

pub const Server = struct {
    app: *App,
    options: Options,
    io: std.Io,
    address: std.Io.net.IpAddress,
    listener: std.Io.net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    open: std.ArrayList(*Connection) = .empty,
    drained: std.Io.Condition = .init,
    /// Numbers connections for the logs, so one connection's lines can be followed.
    next_connection: std.atomic.Value(u64) = .init(1),

    pub fn deinit(self: *Server) void {
        std.debug.assert(self.open.items.len == 0);
        self.open.deinit(self.app.gpa);
        self.listener.deinit(self.io);
        self.* = undefined;
    }

    /// Accepts until `stop`.
    pub fn listen(self: *Server) !void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => {
                    if (self.stopping.load(.acquire)) return;
                    log.warn("accept failed: {t}", .{err});
                    continue;
                },
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            self.admit(stream);
        }
    }

    pub fn listenInNewThread(self: *Server) !std.Thread {
        return std.Thread.spawn(.{}, listenLogged, .{self});
    }

    fn listenLogged(self: *Server) void {
        self.listen() catch |err| log.err("the listener stopped: {t}", .{err});
    }

    /// Stops accepting, closes every connection and waits until each has finished.
    pub fn stop(self: *Server) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        if (self.address.connect(self.io, .{ .mode = .stream })) |wake| wake.close(self.io) else |_| {}

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.open.items) |connection| connection.stream.shutdown(self.io, .both) catch {};
        while (self.app.live.load(.acquire) != 0) self.drained.waitUncancelable(self.io, &self.mutex);
    }

    fn admit(self: *Server, stream: std.Io.net.Stream) void {
        const connection = self.track(stream) catch |err| {
            if (err == error.TooManyConnections) writeAll(self.io, stream, service_unavailable);
            stream.close(self.io);
            return;
        };
        const thread = std.Thread.spawn(.{ .stack_size = thread_stack_size }, Connection.run, .{connection}) catch |err| {
            log.warn("could not start a connection thread: {t}", .{err});
            self.untrack(connection);
            return;
        };
        thread.detach();
    }

    fn track(self: *Server, stream: std.Io.net.Stream) !*Connection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.open.items.len >= self.options.max_connections) return error.TooManyConnections;
        try self.open.ensureUnusedCapacity(self.app.gpa, 1);
        const connection = try Connection.create(self, stream);
        self.open.appendAssumeCapacity(connection);
        _ = self.app.live.fetchAdd(1, .monotonic);
        return connection;
    }

    /// Removes `connection` under the lock before closing it, so `stop` never shuts down a closed socket.
    fn untrack(self: *Server, connection: *Connection) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.open.items, 0..) |candidate, position| {
                if (candidate == connection) {
                    _ = self.open.swapRemove(position);
                    break;
                }
            }
        }
        connection.destroy();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.app.live.fetchSub(1, .release);
        if (self.app.live.load(.acquire) == 0) self.drained.broadcast(self.io);
    }
};

pub fn init(gpa: std.mem.Allocator, app: *App, options: Options) !Server {
    _ = gpa;
    const io = app.shared.io;
    const address = try std.Io.net.IpAddress.parse(options.address, options.port);
    const bound = try listener.listen(address, std.Io.net.default_kernel_backlog);
    return .{ .app = app, .options = options, .io = io, .address = bound.socket.address, .listener = bound };
}

const health_ok = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n";
const health_unavailable = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 12\r\nConnection: close\r\n\r\nunavailable\n";

/// The path of a `GET`, without its query string.
fn requestPath(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const rest = request[4..];
    const end = std.mem.indexOfAny(u8, rest, " ?\r") orelse return null;
    return rest[0..end];
}

fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) void {
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

/// Writes after the handshake go through `outbox` to a sender thread of the connection's own, so
/// no other thread ever blocks on this client's socket.
const Connection = struct {
    server: *Server,
    id: u64,
    stream: std.Io.net.Stream,
    subscriber: hub.Subscriber,
    outbox: Outbox,
    sender: ?std.Thread = null,

    fn create(server: *Server, stream: std.Io.net.Stream) !*Connection {
        const gpa = server.app.gpa;
        const self = try gpa.create(Connection);
        self.* = .{
            .server = server,
            .id = server.next_connection.fetchAdd(1, .monotonic),
            .stream = stream,
            .subscriber = .{
                .registry = subscriptions.Registry.init(gpa, server.app.shared.limits.subscription),
                .delivery = .{ .ptr = self, .sendFn = deliver },
            },
            .outbox = .init(gpa, server.io, server.options.write_buffer_limit),
        };
        return self;
    }

    fn destroy(self: *Connection) void {
        const gpa = self.server.app.gpa;
        std.debug.assert(self.sender == null);
        self.outbox.deinit();
        self.subscriber.registry.deinit();
        self.stream.close(self.server.io);
        gpa.destroy(self);
    }

    fn run(self: *Connection) void {
        const server = self.server;
        defer server.untrack(self);
        log.debug("conn={d} opened", .{self.id});
        if (self.serve()) {
            log.debug("conn={d} closed", .{self.id});
        } else |err| log.debug("conn={d} closed: {t}", .{ self.id, err });
        self.outbox.finish();
        if (self.sender) |sender| sender.join();
        self.sender = null;
    }

    fn sendLoop(self: *Connection) void {
        const gpa = self.server.app.gpa;
        var batch: std.ArrayList(u8) = .empty;
        defer batch.deinit(gpa);
        while (self.outbox.take(&batch)) {
            socket.writeAll(self.stream.socket.handle, batch.items) catch |err| {
                log.debug("conn={d} writes failed: {t}", .{ self.id, err });
                self.outbox.fail();
                self.stream.shutdown(self.server.io, .both) catch {};
                return;
            };
            batch.clearRetainingCapacity();
            if (batch.capacity > retained_batch_capacity) batch.clearAndFree(gpa);
        }
    }

    fn serve(self: *Connection) !void {
        const server = self.server;
        const app = server.app;
        const gpa = app.gpa;
        const io = server.io;
        const handle = self.stream.socket.handle;

        const read_buffer = try gpa.alloc(u8, handshake.max_request);
        defer gpa.free(read_buffer);
        var reader = socket.Reader.init(handle, read_buffer);
        try socket.setSendTimeout(handle, server.options.write_timeout_ms);

        reader.setDeadline(io, server.options.handshake_timeout_ms);
        const request = handshake.readRequest(&reader.interface) catch |err| {
            if (err == error.RequestTooLarge) self.writeRaw(handshake.too_large);
            return err;
        };
        const key = switch (handshake.classify(request)) {
            .upgrade => |key| key,
            .plain => {
                if (try self.respondPlain(request)) return;
                const answer = if (app.information) |information| information.respond(request) else null;
                self.writeRaw(answer orelse handshake.bad_request);
                return;
            },
            .bad_version => return self.writeRaw(handshake.upgrade_required),
            .malformed => return self.writeRaw(handshake.bad_request),
        };
        {
            var upgrade_buffer: [256]u8 = undefined;
            var upgrade: std.Io.Writer = .fixed(&upgrade_buffer);
            try handshake.writeUpgrade(&upgrade, &key);
            try socket.writeAll(handle, upgrade.buffered());
        }
        try reader.clearDeadline();
        const options = server.options;
        try socket.setReceiveTimeout(handle, if (options.ping_interval_ms != 0) options.ping_interval_ms else options.idle_timeout_ms);
        self.sender = try std.Thread.spawn(.{ .stack_size = sender_stack_size }, sendLoop, .{self});

        try app.shared.hub.join(&self.subscriber);
        defer app.shared.hub.leave(&self.subscriber);

        var decoder = frame.Decoder.init(gpa, server.options.max_message_size, .server);
        defer decoder.deinit();
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var signer = nostr.keys.Signer.init();
        defer signer.deinit();
        var responder: Responder = .{ .connection = self, .message = .init(gpa) };
        defer responder.message.deinit();
        var peer: session.Peer = .init(io, app.rates, handshake.headerValue(request, "host"));
        {
            var opening: session.Session = .{
                .shared = app.shared,
                .responder = responder.interface(),
                .subscriber = &self.subscriber,
                .peer = &peer,
            };
            opening.greet() catch return;
        }

        var last_heard = std.Io.Timestamp.now(io, .awake);
        while (true) {
            const message = decoder.next(&reader.interface) catch |err| switch (err) {
                error.ReadFailed => {
                    const timed_out = if (reader.err) |cause| cause == error.Timeout else false;
                    if (!timed_out or decoder.interrupted) return;
                    reader.err = null;
                    const quiet = last_heard.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
                    if (options.idle_timeout_ms != 0 and quiet >= options.idle_timeout_ms) {
                        log.debug("conn={d} idle for {d} ms", .{ self.id, quiet });
                        return self.sendClose(.going_away);
                    }
                    if (options.ping_interval_ms != 0) try self.sendFrame(.ping, "");
                    continue;
                },
                error.EndOfStream => return,
                error.ProtocolViolation, error.InvalidUtf8, error.TooBig, error.OutOfMemory => |violation| {
                    self.sendClose(frame.closeCodeFor(violation));
                    return;
                },
            };
            last_heard = std.Io.Timestamp.now(io, .awake);
            switch (message) {
                .text => |text| {
                    defer _ = arena.reset(.retain_capacity);
                    var current: session.Session = .{
                        .shared = app.shared,
                        .responder = responder.interface(),
                        .subscriber = &self.subscriber,
                        .peer = &peer,
                    };
                    current.handle(.{
                        .arena = arena.allocator(),
                        .signer = signer,
                        .now = std.Io.Timestamp.now(io, .real).toSeconds(),
                        .clock_ns = std.Io.Timestamp.now(io, .awake).nanoseconds,
                    }, text) catch |err| switch (err) {
                        error.RateLimited => {
                            log.info("conn={d} closed: messages faster than rate_limit.messages_per_second", .{self.id});
                            return self.sendClose(.policy_violation);
                        },
                        else => |other| return other,
                    };
                },
                .binary => return self.sendClose(.unsupported_data),
                .ping => |payload| try self.sendFrame(.pong, payload),
                .pong => {},
                .close => return self.sendClose(.normal),
            }
        }
    }

    /// `GET /health` and the metrics path. False leaves the request to the information document.
    fn respondPlain(self: *Connection, request: []const u8) !bool {
        const app = self.server.app;
        const path = requestPath(request) orelse return false;
        if (std.mem.eql(u8, path, "/health")) {
            self.writeRaw(if (self.healthy()) health_ok else health_unavailable);
            return true;
        }
        const exposition = app.metrics orelse return false;
        const metrics_path = app.metrics_path orelse return false;
        if (!std.mem.eql(u8, path, metrics_path)) return false;

        var body: std.Io.Writer.Allocating = .init(app.gpa);
        defer body.deinit();
        const stats = app.shared.store.stats() catch null;
        try exposition.write(&body.writer, .{
            .connections = app.shared.hub.count(),
            .subscriptions = app.shared.hub.subscriptionCount(),
            .write_queue_depth = if (app.shared.writer) |queue| queue.queued() else 0,
            .store_events = if (stats) |present| present.events else null,
            .store_map_used_ratio = if (stats) |present| present.used_ratio else null,
        });
        var response: std.Io.Writer.Allocating = .init(app.gpa);
        defer response.deinit();
        try response.writer.print("HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.written().len, body.written() });
        self.writeRaw(response.written());
        return true;
    }

    fn healthy(self: *Connection) bool {
        if (self.server.stopping.load(.acquire)) return false;
        const stats = self.server.app.shared.store.stats() catch return false;
        const ratio = stats.used_ratio orelse return true;
        return ratio < healthy_map_ratio;
    }

    /// Before the handshake completes; there is no sender thread yet.
    fn writeRaw(self: *Connection, bytes: []const u8) void {
        socket.writeAll(self.stream.socket.handle, bytes) catch {};
    }

    /// From the connection's own thread: waits for room in the outbox.
    fn sendFrame(self: *Connection, opcode: frame.Opcode, payload: []const u8) std.Io.Writer.Error!void {
        self.outbox.send(opcode, payload) catch return error.WriteFailed;
    }

    fn sendClose(self: *Connection, code: frame.CloseCode) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
        self.outbox.send(.close, &payload) catch {};
    }

    /// From other threads: never waits. A client too slow to take what it subscribed to is
    /// disconnected rather than buffered for.
    fn deliver(ptr: *anyopaque, message: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ptr));
        self.outbox.queue(.text, message) catch |err| switch (err) {
            error.Overflow => {
                log.info("conn={d} closed: not reading what it subscribed to (network.write_buffer_limit)", .{self.id});
                self.stream.shutdown(self.server.io, .both) catch {};
            },
            error.Closed => {},
        };
    }
};

const Responder = struct {
    connection: *Connection,
    message: std.Io.Writer.Allocating,

    const vtable: session.Responder.VTable = .{ .begin = begin, .send = send };

    fn interface(self: *Responder) session.Responder {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn begin(ptr: *anyopaque) std.Io.Writer.Error!*std.Io.Writer {
        const self: *Responder = @ptrCast(@alignCast(ptr));
        self.message.clearRetainingCapacity();
        return &self.message.writer;
    }

    fn send(ptr: *anyopaque) std.Io.Writer.Error!void {
        const self: *Responder = @ptrCast(@alignCast(ptr));
        return self.connection.sendFrame(.text, self.message.written());
    }
};

const testing = std.testing;
const memory = @import("../storage/memory.zig");
const Client = @import("../transport/client.zig").Client;
const exchange = @import("../transport/client.zig").exchange;

const Fixture = struct {
    threaded: std.Io.Threaded,
    backing: memory.Memory,
    connections: hub.Hub,
    shared: session.Shared,
    app: App,
    server: Server,
    listener: std.Thread,

    fn start(self: *Fixture, options: Options, information: ?*const nip11.Responses) !void {
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.backing = memory.Memory.init(testing.allocator, io);
        errdefer self.backing.deinit();
        self.connections = hub.Hub.init(testing.allocator, io);
        errdefer self.connections.deinit();
        self.shared = .{ .io = io, .store = self.backing.store(), .hub = &self.connections };
        self.app = .{ .gpa = testing.allocator, .shared = &self.shared, .information = information };
        var bound = options;
        bound.port = 0;
        self.server = try init(testing.allocator, &self.app, bound);
        errdefer self.server.deinit();
        self.listener = try self.server.listenInNewThread();
    }

    fn port(self: *Fixture) u16 {
        return self.server.address.getPort();
    }

    fn stop(self: *Fixture) void {
        self.server.stop();
        self.listener.join();
        self.server.deinit();
        self.connections.deinit();
        self.backing.deinit();
        self.threaded.deinit();
    }
};

fn signedEventMessage(arena: std.mem.Allocator, io: std.Io, secret: u8, content: []const u8) !struct { []const u8, [32]u8 } {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const keypair = try signer.keyPairFromSecretKey([_]u8{secret} ** 32);
    const event = try nostr.event.create(arena, signer, keypair, std.Io.Timestamp.now(io, .real).toSeconds(), 1, &.{}, content, null);
    return .{ try nostr.message.encodeEvent(arena, event), event.id };
}

test "a client publishes over a real connection and is answered OK" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const io = fixture.threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const client = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer client.close();
    const message, const id = try signedEventMessage(arena_state.allocator(), io, 5, "over the wire");
    try client.send(message);

    const expected = try std.fmt.allocPrint(arena_state.allocator(), "[\"OK\",\"{s}\",true,\"\"]", .{std.fmt.bytesToHex(id, .lower)});
    try testing.expectEqualStrings(expected, try client.receive());
}

test "one connection subscribes, another publishes, and the first receives it live" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const io = fixture.threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const reader = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer reader.close();
    try reader.send("[\"REQ\",\"live\",{\"kinds\":[1]}]");
    try testing.expectEqualStrings("[\"EOSE\",\"live\"]", try reader.receive());

    const writer = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer writer.close();
    const message, _ = try signedEventMessage(arena_state.allocator(), io, 6, "over two connections");
    try writer.send(message);
    try testing.expect(std.mem.indexOf(u8, try writer.receive(), ",true,\"\"]") != null);

    const delivered = try reader.receive();
    try testing.expect(std.mem.startsWith(u8, delivered, "[\"EVENT\",\"live\","));
    try testing.expect(std.mem.indexOf(u8, delivered, "over two connections") != null);
}

test "a fragmented message and an interleaved ping are handled" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    var bytes: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    const mask = [4]u8{ 1, 2, 3, 4 };
    const first = "[\"REQ\",";
    try writer.writeAll(&.{ 0x01, 0x80 | @as(u8, first.len) });
    try writer.writeAll(&mask);
    for (first, 0..) |byte, i| try writer.writeByte(byte ^ mask[i % 4]);
    try frame.writeFrame(&writer, .ping, "hi", mask);
    const second = "\"s\",{}]";
    try writer.writeAll(&.{ 0x80, 0x80 | @as(u8, second.len) });
    try writer.writeAll(&mask);
    for (second, 0..) |byte, i| try writer.writeByte(byte ^ mask[i % 4]);
    try client.sendRaw(writer.buffered());

    try testing.expectEqualStrings("hi", (try client.receiveMessage()).pong);
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", try client.receive());
}

test "a protocol violation is answered with a close frame naming it" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .max_message_size = 16 }, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    try client.send("this message is longer than sixteen bytes");
    const closed = (try client.receiveMessage()).close;
    try testing.expectEqual(@as(?u16, @intFromEnum(frame.CloseCode.too_big)), closed.code);
}

test "a plain HTTP request is offered to the information document and otherwise refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const information = try nip11.Responses.render(arena_state.allocator(), .{});
    var fixture: Fixture = undefined;
    try fixture.start(.{}, &information);
    defer fixture.stop();
    const io = fixture.threaded.io();

    const document = try exchange(testing.allocator, io, fixture.port(), "GET / HTTP/1.1\r\nHost: x\r\nAccept: application/nostr+json\r\n\r\n");
    defer testing.allocator.free(document);
    try testing.expect(std.mem.startsWith(u8, document, "HTTP/1.1 200 OK\r\nContent-Type: application/nostr+json\r\n"));
    try testing.expect(std.mem.indexOf(u8, document, "\"supported_nips\":[") != null);

    const refused = try exchange(testing.allocator, io, fixture.port(), "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    defer testing.allocator.free(refused);
    try testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 400 "));

    const old = try exchange(testing.allocator, io, fixture.port(), "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 8\r\n\r\n");
    defer testing.allocator.free(old);
    try testing.expect(std.mem.startsWith(u8, old, "HTTP/1.1 426 "));
}

test "a client that never finishes its handshake is dropped at the timeout" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .handshake_timeout_ms = 200 }, null);
    defer fixture.stop();
    const io = fixture.threaded.io();

    const started = std.Io.Timestamp.now(io, .awake);
    const answer = try exchange(testing.allocator, io, fixture.port(), "GET / HTTP/1.1\r\nHost: slow");
    defer testing.allocator.free(answer);
    const waited = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expectEqual(@as(usize, 0), answer.len);
    try testing.expect(waited >= 150 and waited < 1500);
}

test "a client dripping its handshake a byte at a time is dropped at the deadline" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .handshake_timeout_ms = 200 }, null);
    defer fixture.stop();
    const io = fixture.threaded.io();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", fixture.port());
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try socket.setReceiveTimeout(stream.socket.handle, 50);
    var write_buffer: [16]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var read_buffer: [64]u8 = undefined;
    var reader = socket.Reader.init(stream.socket.handle, &read_buffer);

    const started = std.Io.Timestamp.now(io, .awake);
    const dropped = for (0..40) |_| {
        writer.interface.writeAll("G") catch break true;
        writer.interface.flush() catch break true;
        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => break true,
            error.ReadFailed => if (reader.err.? != error.Timeout) break true,
        };
    } else false;
    const waited = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(dropped);
    try testing.expect(waited >= 150 and waited < 1000);
}

test "connections over the limit are refused with 503" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .max_connections = 1 }, null);
    defer fixture.stop();
    const io = fixture.threaded.io();
    const held = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer held.close();

    const refused = try exchange(testing.allocator, io, fixture.port(), "GET / HTTP/1.1\r\n\r\n");
    defer testing.allocator.free(refused);
    try testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 503 "));
}

test "a subscriber that stops reading is disconnected without slowing a publisher" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .write_buffer_limit = 256 * 1024 }, null);
    defer fixture.stop();
    const io = fixture.threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stalled = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer stalled.close();
    try stalled.send("[\"REQ\",\"firehose\",{}]");
    try testing.expectEqualStrings("[\"EOSE\",\"firehose\"]", try stalled.receive());

    const publisher = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer publisher.close();
    const content = try arena.alloc(u8, 32 * 1024);
    @memset(content, 'x');

    var published: usize = 0;
    while (fixture.connections.count() > 1) : (published += 1) {
        try testing.expect(published < 2000);
        content[0] = 'a' + @as(u8, @intCast(published % 26));
        content[1] = 'a' + @as(u8, @intCast(published / 26 % 26));
        const message, _ = try signedEventMessage(arena, io, 7, content);
        try publisher.send(message);
        try testing.expect(std.mem.indexOf(u8, try publisher.receive(), ",true,") != null);
    }
    try testing.expectEqual(@as(usize, 1), fixture.connections.count());
}

test "a connection over its message rate is closed with policy violation" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    fixture.app.rates = .{ .messages = .{ .per_second = 0.001, .burst = 2 } };
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    for (0..2) |_| {
        try client.send("[\"CLOSE\",\"nothing\"]");
    }
    try client.send("[\"REQ\",\"s\",{}]");
    const closed = (try client.receiveMessage()).close;
    try testing.expectEqual(@as(?u16, @intFromEnum(frame.CloseCode.policy_violation)), closed.code);
}

test "health answers ok, and metrics are served only on their configured path" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    var counters: metrics.Metrics = .{};
    fixture.app.metrics = &counters;
    fixture.app.metrics_path = "/metrics";
    const io = fixture.threaded.io();

    const health = try exchange(testing.allocator, io, fixture.port(), "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    defer testing.allocator.free(health);
    try testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, health, "\r\n\r\nok\n"));

    const exposition = try exchange(testing.allocator, io, fixture.port(), "GET /metrics?x=1 HTTP/1.1\r\nHost: x\r\n\r\n");
    defer testing.allocator.free(exposition);
    try testing.expect(std.mem.startsWith(u8, exposition, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4"));
    try testing.expect(std.mem.indexOf(u8, exposition, "\neasyrelay_connections_active ") != null);
    try testing.expect(std.mem.indexOf(u8, exposition, "\neasyrelay_store_events 0\n") != null);

    fixture.app.metrics_path = null;
    const hidden = try exchange(testing.allocator, io, fixture.port(), "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n");
    defer testing.allocator.free(hidden);
    try testing.expect(std.mem.startsWith(u8, hidden, "HTTP/1.1 400 "));
}

test "a quiet connection is pinged, and one that stays silent is closed as idle" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .ping_interval_ms = 100, .idle_timeout_ms = 350 }, null);
    defer fixture.stop();
    const io = fixture.threaded.io();
    const client = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer client.close();

    const started = std.Io.Timestamp.now(io, .awake);
    var pings: usize = 0;
    const closed = while (true) switch (try client.decoder.next(&client.reader.interface)) {
        .ping => pings += 1,
        .close => |close| break close,
        else => return error.UnexpectedMessage,
    };
    const waited = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(pings >= 2);
    try testing.expect(waited >= 300 and waited < 2000);
    try testing.expectEqual(@as(?u16, @intFromEnum(frame.CloseCode.going_away)), closed.code);
}

test "a client answering pings is never closed as idle" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .ping_interval_ms = 50, .idle_timeout_ms = 200 }, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    const io = fixture.threaded.io();
    const started = std.Io.Timestamp.now(io, .awake);
    var pings: usize = 0;
    while (started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 600) {
        switch (try client.decoder.next(&client.reader.interface)) {
            .ping => |payload| {
                pings += 1;
                try client.sendFrame(.pong, payload);
            },
            else => return error.UnexpectedMessage,
        }
    }
    try testing.expect(pings >= 3);
    try client.send("[\"REQ\",\"s\",{}]");
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", try client.receive());
}

test "a client stalling in the middle of a frame is closed at the next timeout" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .ping_interval_ms = 100, .idle_timeout_ms = 0 }, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    try client.sendRaw(&.{ 0x81, 0x85, 1, 2 });
    const ended = while (true) {
        const message = client.receiveMessage() catch |err| break err;
        if (message != .ping) return error.UnexpectedMessage;
    };
    try testing.expect(ended == error.Closed);
}

fn writeFragment(writer: *std.Io.Writer, opcode: frame.Opcode, fin: bool, payload: []const u8, mask: ?[4]u8) !void {
    std.debug.assert(payload.len < 126);
    try writer.writeByte((if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode)));
    try writer.writeByte((if (mask != null) @as(u8, 0x80) else 0) | @as(u8, @intCast(payload.len)));
    const key = mask orelse return writer.writeAll(payload);
    try writer.writeAll(&key);
    for (payload, 0..) |byte, position| try writer.writeByte(byte ^ key[position % 4]);
}

fn expectClosedWith(client: *Client, code: frame.CloseCode) !void {
    const closed = (try client.receiveMessage()).close;
    try testing.expectEqual(@as(?u16, @intFromEnum(code)), closed.code);
}

test "a message in a thousand one-byte fragments is assembled" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    const message = "[\"REQ\",\"s\",{}" ++ " " ** 985 ++ "]";
    var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    for (message, 0..) |byte, position| {
        const opcode: frame.Opcode = if (position == 0) .text else .continuation;
        try writeFragment(&bytes.writer, opcode, position == message.len - 1, &.{byte}, .{ 9, 8, 7, 6 });
    }
    try client.sendRaw(bytes.written());
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", try client.receive());
}

test "fragments that add up past the message limit close the connection as too big" {
    var fixture: Fixture = undefined;
    try fixture.start(.{ .max_message_size = 256 }, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    try writeFragment(&bytes.writer, .text, false, "x" ** 100, .{ 1, 2, 3, 4 });
    for (0..10) |_| try writeFragment(&bytes.writer, .continuation, false, "x" ** 100, .{ 1, 2, 3, 4 });
    client.sendRaw(bytes.written()) catch {};
    try expectClosedWith(client, .too_big);
}

test "a new message started inside a fragmented one is a protocol error" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    var bytes: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeFragment(&writer, .text, false, "[\"REQ\",", .{ 1, 2, 3, 4 });
    try writeFragment(&writer, .text, true, "\"s\",{}]", .{ 1, 2, 3, 4 });
    try client.sendRaw(writer.buffered());
    try expectClosedWith(client, .protocol_error);
}

test "an unmasked frame from a client is a protocol error" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const client = try Client.connect(testing.allocator, fixture.threaded.io(), fixture.port(), 2000);
    defer client.close();

    var bytes: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try frame.writeFrame(&writer, .text, "[\"CLOSE\",\"s\"]", null);
    try client.sendRaw(writer.buffered());
    try expectClosedWith(client, .protocol_error);
}

test "text that is not UTF-8 closes with invalid payload, and binary with unsupported data" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const io = fixture.threaded.io();

    const text_client = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer text_client.close();
    try text_client.send("[\"CLOSE\",\"\xff\xfe\"]");
    try expectClosedWith(text_client, .invalid_payload);

    const binary_client = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer binary_client.close();
    try binary_client.sendFrame(.binary, "[]");
    try expectClosedWith(binary_client, .unsupported_data);
}

test "a ping flood is answered without disturbing other connections" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    const io = fixture.threaded.io();

    const flooder = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer flooder.close();
    var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bytes.deinit();
    for (0..5000) |_| try frame.writeFrame(&bytes.writer, .ping, "flood", .{ 1, 2, 3, 4 });
    try flooder.sendRaw(bytes.written());

    const bystander = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer bystander.close();
    try bystander.send("[\"REQ\",\"s\",{}]");
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", try bystander.receive());
}

test "a connection flooding events is limited while a well-behaved one is served promptly" {
    var fixture: Fixture = undefined;
    try fixture.start(.{}, null);
    defer fixture.stop();
    fixture.app.rates = .{};
    const io = fixture.threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const watcher = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer watcher.close();
    try watcher.send("[\"REQ\",\"bystander\",{\"kinds\":[1],\"#t\":[\"bystander\"]}]");
    try testing.expectEqualStrings("[\"EOSE\",\"bystander\"]", try watcher.receive());

    var flood: std.Io.Writer.Allocating = .init(testing.allocator);
    defer flood.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const flooder_key = try signer.keyPairFromSecretKey([_]u8{20} ** 32);
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    for (0..90) |position| {
        const content = try std.fmt.allocPrint(arena, "flood {d}", .{position});
        const event = try nostr.event.create(arena, signer, flooder_key, now, 1, &.{}, content, null);
        try frame.writeFrame(&flood.writer, .text, try nostr.message.encodeEvent(arena, event), .{ 1, 2, 3, 4 });
    }
    const flooder = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer flooder.close();
    try flooder.sendRaw(flood.written());

    const bystander = try Client.connect(testing.allocator, io, fixture.port(), 2000);
    defer bystander.close();
    const bystander_key = try signer.keyPairFromSecretKey([_]u8{21} ** 32);
    var slowest_ms: i64 = 0;
    for (0..10) |position| {
        const content = try std.fmt.allocPrint(arena, "bystander {d}", .{position});
        const event = try nostr.event.create(arena, signer, bystander_key, now, 1, &.{&.{ "t", "bystander" }}, content, null);
        const sent = std.Io.Timestamp.now(io, .awake);
        try bystander.send(try nostr.message.encodeEvent(arena, event));
        try testing.expect(std.mem.indexOf(u8, try bystander.receive(), ",true,") != null);
        slowest_ms = @max(slowest_ms, sent.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds());
    }
    try testing.expect(slowest_ms < 250);
    for (0..10) |_| try testing.expect(std.mem.indexOf(u8, try watcher.receive(), "bystander") != null);

    var limited: usize = 0;
    for (0..90) |_| {
        if (std.mem.indexOf(u8, try flooder.receive(), "rate-limited:") != null) limited += 1;
    }
    try testing.expect(limited >= 90 - 50);
}
