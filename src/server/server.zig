const std = @import("std");
const nostr = @import("nostr");

const frame = @import("../transport/frame.zig");
const handshake = @import("../transport/handshake.zig");
const listener = @import("../transport/listener.zig");
const socket = @import("../transport/socket.zig");
const hub = @import("../relay/hub.zig");
const nip11 = @import("../relay/nip11.zig");
const session = @import("../relay/session.zig");
const subscriptions = @import("../relay/subscriptions.zig");

const log = std.log.scoped(.server);

pub const App = struct {
    gpa: std.mem.Allocator,
    shared: *const session.Shared,
    live: std.atomic.Value(usize) = .init(0),
    information: ?*const nip11.Responses = null,
};

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    max_connections: usize = 1024,
    handshake_timeout_ms: u32 = 5000,
    max_message_size: usize = 131072,
};

const thread_stack_size = 4 * 1024 * 1024;
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

fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) void {
    var buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

const Connection = struct {
    server: *Server,
    stream: std.Io.net.Stream,
    subscriber: hub.Subscriber,
    write_mutex: std.Io.Mutex = .init,
    write_buffer: [4096]u8 = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    broken: std.atomic.Value(bool) = .init(false),

    fn create(server: *Server, stream: std.Io.net.Stream) !*Connection {
        const gpa = server.app.gpa;
        const self = try gpa.create(Connection);
        self.* = .{
            .server = server,
            .stream = stream,
            .subscriber = .{
                .registry = subscriptions.Registry.init(gpa, server.app.shared.limits.subscription),
                .delivery = .{ .ptr = self, .sendFn = deliver },
            },
        };
        self.writer = stream.writer(server.io, &self.write_buffer);
        return self;
    }

    fn destroy(self: *Connection) void {
        const gpa = self.server.app.gpa;
        self.subscriber.registry.deinit();
        self.stream.close(self.server.io);
        gpa.destroy(self);
    }

    fn run(self: *Connection) void {
        const server = self.server;
        defer server.untrack(self);
        self.serve() catch |err| log.debug("connection ended: {t}", .{err});
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

        reader.setDeadline(io, server.options.handshake_timeout_ms);
        const request = handshake.readRequest(&reader.interface) catch |err| {
            if (err == error.RequestTooLarge) self.writeRaw(handshake.too_large);
            return err;
        };
        const key = switch (handshake.classify(request)) {
            .upgrade => |key| key,
            .plain => {
                const answer = if (app.information) |information| information.respond(request) else null;
                self.writeRaw(answer orelse handshake.bad_request);
                return;
            },
            .bad_version => return self.writeRaw(handshake.upgrade_required),
            .malformed => return self.writeRaw(handshake.bad_request),
        };
        {
            self.write_mutex.lockUncancelable(io);
            defer self.write_mutex.unlock(io);
            try handshake.writeUpgrade(&self.writer.interface, &key);
            try self.writer.interface.flush();
        }
        try reader.clearDeadline();

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

        while (true) {
            const message = decoder.next(&reader.interface) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                error.ProtocolViolation, error.InvalidUtf8, error.TooBig, error.OutOfMemory => |violation| {
                    self.sendClose(frame.closeCodeFor(violation));
                    return;
                },
            };
            switch (message) {
                .text => |text| {
                    defer _ = arena.reset(.retain_capacity);
                    var current: session.Session = .{
                        .shared = app.shared,
                        .responder = responder.interface(),
                        .subscriber = &self.subscriber,
                    };
                    try current.handle(.{
                        .arena = arena.allocator(),
                        .signer = signer,
                        .now = std.Io.Timestamp.now(io, .real).toSeconds(),
                    }, text);
                },
                .binary => return self.sendClose(.unsupported_data),
                .ping => |payload| try self.sendFrame(.pong, payload),
                .pong => {},
                .close => return self.sendClose(.normal),
            }
        }
    }

    fn writeRaw(self: *Connection, bytes: []const u8) void {
        self.write_mutex.lockUncancelable(self.server.io);
        defer self.write_mutex.unlock(self.server.io);
        self.writer.interface.writeAll(bytes) catch return;
        self.writer.interface.flush() catch {};
    }

    fn sendFrame(self: *Connection, opcode: frame.Opcode, payload: []const u8) std.Io.Writer.Error!void {
        if (self.broken.load(.acquire)) return error.WriteFailed;
        self.write_mutex.lockUncancelable(self.server.io);
        defer self.write_mutex.unlock(self.server.io);
        frame.writeFrame(&self.writer.interface, opcode, payload, null) catch |err| return self.fail(err);
        self.writer.interface.flush() catch |err| return self.fail(err);
    }

    fn sendClose(self: *Connection, code: frame.CloseCode) void {
        self.write_mutex.lockUncancelable(self.server.io);
        defer self.write_mutex.unlock(self.server.io);
        frame.writeClose(&self.writer.interface, code, null) catch return;
        self.writer.interface.flush() catch {};
    }

    /// A failed write leaves the frame half sent, so the connection cannot be written to again.
    fn fail(self: *Connection, err: std.Io.Writer.Error) std.Io.Writer.Error {
        self.broken.store(true, .release);
        self.stream.shutdown(self.server.io, .both) catch {};
        return err;
    }

    fn deliver(ptr: *anyopaque, message: []const u8) void {
        const self: *Connection = @ptrCast(@alignCast(ptr));
        self.sendFrame(.text, message) catch |err| log.debug("dropping a delivery: {t}", .{err});
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
