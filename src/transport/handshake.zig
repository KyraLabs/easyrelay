const std = @import("std");

pub const max_request = 8192;

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const ReadError = error{ RequestTooLarge, EndOfStream, ReadFailed };

/// Reads up to the end of the request headers. The result aliases the reader's buffer,
/// which must hold `max_request` bytes.
pub fn readRequest(reader: *std.Io.Reader) ReadError![]const u8 {
    std.debug.assert(reader.buffer.len >= max_request);
    var scanned: usize = 0;
    while (true) {
        const buffered = reader.buffered();
        if (std.mem.indexOfPos(u8, buffered, scanned -| 3, "\r\n\r\n")) |end| {
            return reader.take(end + 4) catch unreachable;
        }
        scanned = buffered.len;
        if (buffered.len >= max_request) return error.RequestTooLarge;
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

pub const Kind = union(enum) {
    upgrade: [24]u8,
    plain,
    bad_version,
    malformed,
};

/// Decides what a complete request asks for.
pub fn classify(request: []const u8) Kind {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return .malformed;
    const request_line = request[0..line_end];
    if (!std.mem.endsWith(u8, request_line, " HTTP/1.1")) return .malformed;

    var upgrade = false;
    var connection = false;
    var version: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var headers = std.mem.splitSequence(u8, request[line_end + 2 ..], "\r\n");
    while (headers.next()) |header| {
        if (header.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return .malformed;
        const name = std.mem.trim(u8, header[0..colon], " \t");
        const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            connection = hasToken(value, "upgrade");
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) {
            version = value;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            key = value;
        }
    }
    if (!upgrade and !connection and key == null) return .plain;
    if (!std.mem.startsWith(u8, request_line, "GET ") or !upgrade or !connection) return .malformed;
    if (version == null or !std.mem.eql(u8, version.?, "13")) return .bad_version;
    const text = key orelse return .malformed;
    if (text.len != 24) return .malformed;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return .malformed;
    if (size != 16) return .malformed;
    var decoded: [16]u8 = undefined;
    decoder.decode(&decoded, text) catch return .malformed;
    return .{ .upgrade = text[0..24].* };
}

fn hasToken(value: []const u8, token: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |candidate| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, candidate, " \t"), token)) return true;
    }
    return false;
}

pub fn acceptKey(key: *const [24]u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

pub fn writeUpgrade(writer: *std.Io.Writer, key: *const [24]u8) std.Io.Writer.Error!void {
    try writer.print("HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptKey(key)});
}

pub const bad_request = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
pub const upgrade_required = "HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
pub const too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";

const testing = std.testing;

const upgrade_request = "GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUpgrade: websocket\r\n" ++
    "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Version: 13\r\n\r\n";

test "the RFC 6455 handshake example is accepted with the RFC's accept key" {
    const kind = classify(upgrade_request);
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", &kind.upgrade);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey(&kind.upgrade));

    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try writeUpgrade(&writer, &kind.upgrade);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n") != null);
}

test "a request without upgrade headers is plain HTTP, and a broken upgrade is refused" {
    try testing.expect(classify("GET / HTTP/1.1\r\nAccept: application/nostr+json\r\n\r\n") == .plain);
    try testing.expect(classify("OPTIONS / HTTP/1.1\r\nHost: x\r\n\r\n") == .plain);
    try testing.expect(classify("GET / HTTP/1.0\r\n\r\n") == .malformed);
    try testing.expect(classify("GET / HTTP/1.1\r\nbroken header\r\n\r\n") == .malformed);

    const no_version = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    try testing.expect(classify(no_version) == .bad_version);
    const short_key = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try testing.expect(classify(short_key) == .malformed);
    const long_key = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAAAA\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try testing.expect(classify(long_key) == .malformed);
    const padded_key = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAA===\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try testing.expect(classify(padded_key) == .malformed);
    const post = "POST / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    try testing.expect(classify(post) == .malformed);
}

test "readRequest stops at the end of the headers and bounds the request" {
    var buffer: [max_request]u8 = undefined;
    const pipelined = upgrade_request ++ "\x81\x85";
    var reader: std.Io.Reader = .fixed(pipelined);
    reader.buffer = &buffer;
    @memcpy(buffer[0..pipelined.len], pipelined);
    reader.end = pipelined.len;
    try testing.expectEqualStrings(upgrade_request, try readRequest(&reader));
    try testing.expectEqualSlices(u8, "\x81\x85", reader.buffered());

    var endless: [max_request + 16]u8 = undefined;
    @memset(&endless, 'a');
    var flood: std.Io.Reader = .fixed(&endless);
    flood.buffer = endless[0..max_request];
    flood.end = max_request;
    try testing.expectError(error.RequestTooLarge, readRequest(&flood));
}

test "any 24-character key is classified without crashing" {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    var prng: std.Random.DefaultPrng = .init(0x6455);
    const random = prng.random();
    const head = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ";
    var request = (head ++ "x" ** 24 ++ "\r\n\r\n").*;
    for (0..20_000) |_| {
        for (request[head.len..][0..24]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        switch (classify(&request)) {
            .upgrade, .malformed => {},
            .plain, .bad_version => return error.TestUnexpectedResult,
        }
    }
}
