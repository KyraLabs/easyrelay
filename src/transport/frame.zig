const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    fn isControl(self: Opcode) bool {
        return @intFromEnum(self) & 0x8 != 0;
    }
};

pub const max_control_payload = 125;

pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    too_big = 1009,
    internal_error = 1011,
    _,
};

pub const Error = error{
    /// RSV bits set, an unknown opcode, an unmasked client frame, a fragmented or oversized
    /// control frame, a continuation with nothing to continue, or a malformed close payload.
    ProtocolViolation,
    /// A text message that is not valid UTF-8.
    InvalidUtf8,
    /// A frame or an assembled message over the configured bound.
    TooBig,
    OutOfMemory,
};

pub fn closeCodeFor(err: Error) CloseCode {
    return switch (err) {
        error.ProtocolViolation => .protocol_error,
        error.InvalidUtf8 => .invalid_payload,
        error.TooBig => .too_big,
        error.OutOfMemory => .internal_error,
    };
}

pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,
    ping: []const u8,
    pong: []const u8,
    close: Close,
};

pub const Close = struct {
    code: ?u16,
    reason: []const u8,
};

pub const Role = enum { server, client };

/// Reads frames and returns whole messages. A returned slice is valid until the next call.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    max_message: usize,
    role: Role,
    assembled: std.ArrayList(u8) = .empty,
    fragmented: ?Opcode = null,
    control: [max_control_payload]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, max_message: usize, role: Role) Decoder {
        return .{ .gpa = gpa, .max_message = max_message, .role = role };
    }

    pub fn deinit(self: *Decoder) void {
        self.assembled.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn next(self: *Decoder, reader: *std.Io.Reader) (Error || std.Io.Reader.Error)!Message {
        if (self.fragmented == null) self.assembled.clearRetainingCapacity();
        while (true) {
            const header = try readHeader(reader, self.role);
            if (header.opcode.isControl()) {
                if (!header.fin or header.length > max_control_payload) return error.ProtocolViolation;
                const payload = self.control[0..@intCast(header.length)];
                try reader.readSliceAll(payload);
                if (header.mask) |mask| unmask(mask, payload);
                return switch (header.opcode) {
                    .ping => .{ .ping = payload },
                    .pong => .{ .pong = payload },
                    .close => .{ .close = try parseClose(payload) },
                    else => error.ProtocolViolation,
                };
            }

            const kind: Opcode = switch (header.opcode) {
                .text, .binary => blk: {
                    if (self.fragmented != null) return error.ProtocolViolation;
                    break :blk header.opcode;
                },
                .continuation => self.fragmented orelse return error.ProtocolViolation,
                else => return error.ProtocolViolation,
            };
            if (header.length > self.max_message - self.assembled.items.len) return error.TooBig;
            const start = self.assembled.items.len;
            const length: usize = @intCast(header.length);
            try self.assembled.ensureTotalCapacity(self.gpa, start + length);
            self.assembled.items.len = start + length;
            const payload = self.assembled.items[start..];
            reader.readSliceAll(payload) catch |err| {
                self.assembled.items.len = start;
                return err;
            };
            if (header.mask) |mask| unmask(mask, payload);

            if (!header.fin) {
                self.fragmented = kind;
                continue;
            }
            self.fragmented = null;
            const message = self.assembled.items;
            if (kind == .text) {
                if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
                return .{ .text = message };
            }
            return .{ .binary = message };
        }
    }
};

const Header = struct {
    fin: bool,
    opcode: Opcode,
    mask: ?[4]u8,
    length: u64,
};

fn readHeader(reader: *std.Io.Reader, role: Role) (Error || std.Io.Reader.Error)!Header {
    const first = (try reader.takeArray(2)).*;
    if (first[0] & 0x70 != 0) return error.ProtocolViolation;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(first[0])));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.ProtocolViolation,
    }
    const masked = first[1] & 0x80 != 0;
    if (masked != (role == .server)) return error.ProtocolViolation;

    var length: u64 = first[1] & 0x7F;
    if (length == 126) {
        length = std.mem.readInt(u16, try reader.takeArray(2), .big);
        if (length < 126) return error.ProtocolViolation;
    } else if (length == 127) {
        length = std.mem.readInt(u64, try reader.takeArray(8), .big);
        if (length >> 63 != 0 or length <= std.math.maxInt(u16)) return error.ProtocolViolation;
    }
    const mask: ?[4]u8 = if (masked) (try reader.takeArray(4)).* else null;
    return .{ .fin = first[0] & 0x80 != 0, .opcode = opcode, .mask = mask, .length = length };
}

fn unmask(mask: [4]u8, payload: []u8) void {
    for (payload, 0..) |*byte, position| byte.* ^= mask[position % 4];
}

fn parseClose(payload: []const u8) Error!Close {
    if (payload.len == 0) return .{ .code = null, .reason = "" };
    if (payload.len == 1) return error.ProtocolViolation;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const valid = switch (code) {
        1000...1003, 1007...1011, 3000...4999 => true,
        else => false,
    };
    if (!valid) return error.ProtocolViolation;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidUtf8;
    return .{ .code = code, .reason = payload[2..] };
}

/// Writes one unfragmented frame; a client must pass a mask, a server must not.
pub fn writeFrame(writer: *std.Io.Writer, opcode: Opcode, payload: []const u8, mask: ?[4]u8) std.Io.Writer.Error!void {
    std.debug.assert(!opcode.isControl() or payload.len <= max_control_payload);
    const mask_bit: u8 = if (mask != null) 0x80 else 0;
    try writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try writer.writeByte(mask_bit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(mask_bit | 126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(mask_bit | 127);
        try writer.writeInt(u64, payload.len, .big);
    }
    const key = mask orelse return writer.writeAll(payload);
    try writer.writeAll(&key);
    for (payload, 0..) |byte, position| try writer.writeByte(byte ^ key[position % 4]);
}

pub fn writeClose(writer: *std.Io.Writer, code: CloseCode, mask: ?[4]u8) std.Io.Writer.Error!void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
    try writeFrame(writer, .close, &payload, mask);
}

const testing = std.testing;

fn decodeAll(bytes: []const u8, role: Role, max_message: usize, out: *std.ArrayList(Message), arena: std.mem.Allocator) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoder = Decoder.init(testing.allocator, max_message, role);
    defer decoder.deinit();
    while (true) {
        const message = decoder.next(&reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        try out.append(arena, switch (message) {
            .text => |text| .{ .text = try arena.dupe(u8, text) },
            .binary => |binary| .{ .binary = try arena.dupe(u8, binary) },
            .ping => |payload| .{ .ping = try arena.dupe(u8, payload) },
            .pong => |payload| .{ .pong = try arena.dupe(u8, payload) },
            .close => |close| .{ .close = .{ .code = close.code, .reason = try arena.dupe(u8, close.reason) } },
        });
    }
}

test "the RFC 6455 section 5.7 examples decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server: std.ArrayList(Message) = .empty;
    try decodeAll(&.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, .server, 1024, &server, arena);
    try decodeAll(&.{ 0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, .server, 1024, &server, arena);
    try testing.expectEqualStrings("Hello", server.items[0].text);
    try testing.expectEqualStrings("Hello", server.items[1].pong);

    var client: std.ArrayList(Message) = .empty;
    try decodeAll(&.{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f }, .client, 1024, &client, arena);
    try decodeAll(&.{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f }, .client, 1024, &client, arena);
    try decodeAll(&.{ 0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f }, .client, 1024, &client, arena);
    try testing.expectEqualStrings("Hello", client.items[0].text);
    try testing.expectEqualStrings("Hello", client.items[1].text);
    try testing.expectEqualStrings("Hello", client.items[2].ping);
}

test "a control frame between fragments is returned without breaking the message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var bytes: std.Io.Writer.Allocating = .init(arena_state.allocator());
    const mask = [4]u8{ 1, 2, 3, 4 };
    const w = &bytes.writer;
    try w.writeAll(&.{ 0x01, 0x83 });
    try w.writeAll(&mask);
    for ("Hel", 0..) |byte, i| try w.writeByte(byte ^ mask[i % 4]);
    try writeFrame(w, .ping, "p", mask);
    try w.writeAll(&.{ 0x80, 0x82 });
    try w.writeAll(&mask);
    for ("lo", 0..) |byte, i| try w.writeByte(byte ^ mask[i % 4]);

    var messages: std.ArrayList(Message) = .empty;
    try decodeAll(bytes.written(), .server, 1024, &messages, arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqualStrings("p", messages.items[0].ping);
    try testing.expectEqualStrings("Hello", messages.items[1].text);
}

test "frames written by writeFrame decode, at every length encoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]usize{ 0, 125, 126, 65535, 65536 }) |length| {
        const payload = try arena.alloc(u8, length);
        for (payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try writeFrame(&bytes.writer, .binary, payload, .{ 9, 8, 7, 6 });
        var messages: std.ArrayList(Message) = .empty;
        try decodeAll(bytes.written(), .server, 1 << 20, &messages, arena);
        try testing.expectEqualSlices(u8, payload, messages.items[0].binary);
    }
}

/// Fills as much of the buffer as it can per call, the way a socket read does.
const Chunked = struct {
    remaining: []const u8,
    reader: std.Io.Reader,

    fn init(bytes: []const u8, buffer: []u8) Chunked {
        return .{ .remaining = bytes, .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream } } };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Chunked = @fieldParentPtr("reader", reader);
        if (self.remaining.len == 0) return error.EndOfStream;
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        const count = @min(dest.len, self.remaining.len);
        @memcpy(dest[0..count], self.remaining[0..count]);
        self.remaining = self.remaining[count..];
        writer.advance(count);
        return count;
    }
};

test "a frame header split across buffer refills keeps its FIN bit" {
    const mask = [4]u8{ 1, 2, 3, 4 };
    for (0..12) |lead| {
        var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer bytes.deinit();
        try writeFrame(&bytes.writer, .text, ("y" ** 12)[0..lead], mask);
        try writeFrame(&bytes.writer, .text, "abc", mask);
        for (8..17) |capacity| {
            var buffer: [16]u8 = undefined;
            var chunked: Chunked = .init(bytes.written(), buffer[0..capacity]);
            var decoder: Decoder = .init(testing.allocator, 1024, .server);
            defer decoder.deinit();
            try testing.expectEqualStrings(("y" ** 12)[0..lead], (try decoder.next(&chunked.reader)).text);
            try testing.expectEqualStrings("abc", (try decoder.next(&chunked.reader)).text);
            try testing.expectError(error.EndOfStream, decoder.next(&chunked.reader));
        }
    }
}

fn expectViolation(bytes: []const u8, role: Role, max_message: usize, expected: Error) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var messages: std.ArrayList(Message) = .empty;
    try testing.expectError(expected, decodeAll(bytes, role, max_message, &messages, arena_state.allocator()));
}

test "malformed and hostile frames are refused with the right reason" {
    const m = [4]u8{ 0, 0, 0, 0 };
    try expectViolation(&([_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' }), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0xC1, 0x80 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x83, 0x80 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x80, 0x80 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x09, 0x80 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x89, 0xFE, 0x00, 0x7E } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x82, 0xFE, 0x00, 0x05 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x82, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } ++ m), .server, 1024, error.TooBig);
    try expectViolation(&([_]u8{ 0x01, 0x82 } ++ m ++ [_]u8{ 'a', 'b' } ++ [_]u8{ 0x01, 0x80 } ++ m), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x01, 0x83 } ++ m ++ [_]u8{ 'a', 'b', 'c' } ++ [_]u8{ 0x80, 0x83 } ++ m ++ [_]u8{ 'd', 'e', 'f' }), .server, 5, error.TooBig);
    try expectViolation(&([_]u8{ 0x81, 0x82 } ++ m ++ [_]u8{ 0xC3, 0x28 }), .server, 1024, error.InvalidUtf8);
    try expectViolation(&([_]u8{ 0x88, 0x81 } ++ m ++ [_]u8{0x03}), .server, 1024, error.ProtocolViolation);
    try expectViolation(&([_]u8{ 0x88, 0x82 } ++ m ++ [_]u8{ 0x03, 0xED }), .server, 1024, error.ProtocolViolation);
}

test "a close frame carries its code and reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var bytes: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeFrame(&bytes.writer, .close, &.{ 0x03, 0xE8, 'b', 'y', 'e' }, .{ 5, 6, 7, 8 });
    try writeFrame(&bytes.writer, .close, "", .{ 5, 6, 7, 8 });
    var messages: std.ArrayList(Message) = .empty;
    try decodeAll(bytes.written(), .server, 1024, &messages, arena_state.allocator());
    try testing.expectEqual(@as(?u16, 1000), messages.items[0].close.code);
    try testing.expectEqualStrings("bye", messages.items[0].close.reason);
    try testing.expectEqual(@as(?u16, null), messages.items[1].close.code);
}

fn fuzzDecoder(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const length = smith.slice(&buffer);
    var reader: std.Io.Reader = .fixed(buffer[0..length]);
    var decoder = Decoder.init(testing.allocator, 1024, .server);
    defer decoder.deinit();
    for (0..64) |_| {
        const message = decoder.next(&reader) catch return;
        switch (message) {
            .text, .binary => |payload| try testing.expect(payload.len <= 1024),
            .ping, .pong => |payload| try testing.expect(payload.len <= max_control_payload),
            .close => {},
        }
    }
}

test "fuzz the frame decoder" {
    try testing.fuzz({}, fuzzDecoder, .{});
}

fn decodeHostile(bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var decoder = Decoder.init(testing.allocator, 1024, .server);
    defer decoder.deinit();
    for (0..64) |_| {
        const message = decoder.next(&reader) catch return;
        switch (message) {
            .text, .binary => |payload| try testing.expect(payload.len <= 1024),
            .ping, .pong => |payload| try testing.expect(payload.len <= max_control_payload),
            .close => {},
        }
    }
}

test "random and mutated frames never crash the decoder or exceed its bounds" {
    var prng = std.Random.DefaultPrng.init(0x6455);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    for (0..20_000) |round| {
        const length = random.uintLessThan(usize, buffer.len);
        const input = buffer[0..length];
        if (round % 2 == 0) {
            random.bytes(input);
        } else {
            var writer: std.Io.Writer = .fixed(&buffer);
            const opcodes = [_]Opcode{ .text, .binary, .continuation, .ping, .close };
            while (writer.end < buffer.len / 2) {
                var payload: [40]u8 = undefined;
                random.bytes(&payload);
                writeFrame(&writer, opcodes[random.uintLessThan(usize, opcodes.len)], payload[0..random.uintLessThan(usize, 40)], .{ 1, 2, 3, 4 }) catch break;
            }
            const written = buffer[0..writer.end];
            for (0..1 + random.uintLessThan(usize, 4)) |_| {
                if (written.len == 0) break;
                written[random.uintLessThan(usize, written.len)] ^= @as(u8, 1) << random.int(u3);
            }
            try decodeHostile(written);
            continue;
        }
        try decodeHostile(input);
    }
}
