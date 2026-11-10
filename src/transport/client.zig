const std = @import("std");

const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const socket = @import("socket.zig");

/// A minimal WebSocket client for tests: text messages, masked as RFC 6455 requires.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: socket.Reader,
    writer: std.Io.net.Stream.Writer,
    decoder: frame.Decoder,
    prng: std.Random.DefaultPrng,
    read_buffer: []u8,
    write_buffer: []u8,

    pub const Error = error{ HandshakeRefused, Closed, Timeout, UnexpectedMessage } || std.Io.net.IpAddress.ConnectError ||
        std.Io.Writer.Error || frame.Error || std.Io.Reader.Error || handshake.ReadError || error{Unexpected};

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, port: u16, timeout_ms: u32) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        self.stream = try address.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.read_buffer = try gpa.alloc(u8, 1 << 20);
        errdefer gpa.free(self.read_buffer);
        self.write_buffer = try gpa.alloc(u8, 4096);
        errdefer gpa.free(self.write_buffer);
        self.gpa = gpa;
        self.io = io;
        self.reader = .init(self.stream.socket.handle, self.read_buffer);
        self.writer = self.stream.writer(io, self.write_buffer);
        self.decoder = .init(gpa, 1 << 20, .client);
        errdefer self.decoder.deinit();
        self.prng = .init(@intCast(std.Io.Timestamp.now(io, .awake).nanoseconds));
        try self.setTimeout(timeout_ms);

        var nonce: [16]u8 = undefined;
        self.prng.random().bytes(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        try self.writer.interface.print("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{&key});
        try self.writer.interface.flush();

        const response = try handshake.readRequest(&self.reader.interface);
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101 ")) return error.HandshakeRefused;
        const expected = handshake.acceptKey(&key);
        if (std.mem.indexOf(u8, response, &expected) == null) return error.HandshakeRefused;
        return self;
    }

    pub fn close(self: *Client) void {
        frame.writeClose(&self.writer.interface, .normal, self.mask()) catch {};
        self.writer.interface.flush() catch {};
        self.stream.close(self.io);
        self.decoder.deinit();
        self.gpa.free(self.write_buffer);
        self.gpa.free(self.read_buffer);
        self.gpa.destroy(self);
    }

    pub fn setTimeout(self: *Client, milliseconds: u32) error{Unexpected}!void {
        try socket.setReceiveTimeout(self.stream.socket.handle, milliseconds);
    }

    pub fn sendFrame(self: *Client, opcode: frame.Opcode, payload: []const u8) !void {
        try frame.writeFrame(&self.writer.interface, opcode, payload, self.mask());
        try self.writer.interface.flush();
    }

    pub fn sendRaw(self: *Client, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    pub fn send(self: *Client, text: []const u8) !void {
        try self.sendFrame(.text, text);
    }

    /// The next message; a ping is answered on the way. The slice is valid until the next call.
    pub fn receiveMessage(self: *Client) !frame.Message {
        while (true) {
            const message = self.decoder.next(&self.reader.interface) catch |err| switch (err) {
                error.ReadFailed => return if (timedOut(self.reader.err)) error.Timeout else error.Closed,
                error.EndOfStream => return error.Closed,
                else => return err,
            };
            switch (message) {
                .ping => |payload| try self.sendFrame(.pong, payload),
                else => return message,
            }
        }
    }

    pub fn receive(self: *Client) ![]const u8 {
        return switch (try self.receiveMessage()) {
            .text => |text| text,
            .close => error.Closed,
            else => error.UnexpectedMessage,
        };
    }

    fn mask(self: *Client) [4]u8 {
        var key: [4]u8 = undefined;
        self.prng.random().bytes(&key);
        return key;
    }
};

fn timedOut(err: ?socket.ReadError) bool {
    return if (err) |present| present == error.Timeout else false;
}

/// Sends `request` as it is over a fresh connection and returns everything the server writes back.
pub fn exchange(gpa: std.mem.Allocator, io: std.Io, port: u16, request: []const u8) ![]u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try socket.setReceiveTimeout(stream.socket.handle, 2000);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = socket.Reader.init(stream.socket.handle, &read_buffer);
    var response: std.Io.Writer.Allocating = .init(gpa);
    errdefer response.deinit();
    _ = reader.interface.streamRemaining(&response.writer) catch |err| switch (err) {
        error.ReadFailed => if (reader.err == null or reader.err.? != error.ConnectionReset) return error.ReadFailed,
        else => return err,
    };
    return response.toOwnedSlice();
}
