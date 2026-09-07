//! The on-disk event record.
//!
//! Events are stored as a compact binary record rather than as JSON, so that a
//! read serves an event straight from the page cache: the fixed-size fields sit
//! at constant offsets, and `content` and every tag field are slices into the
//! memory map rather than copies. The layout is specified in docs/storage.md.
//!
//! Nothing here touches LMDB. The format is the store's, but it is bytes in and
//! bytes out, which is what makes it testable without an environment.

const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;
const Tag = nostr.event.Tag;

pub const EncodeError = error{
    BufferTooSmall,
    /// More tags, or a longer tag field, than the format can address. Inbound
    /// events are bounded well below this by `limits` in docs/configuration.md;
    /// reaching it means validation did not run.
    TooLarge,
};

pub const DecodeError = error{
    OutOfMemory,
    /// The record is truncated or its lengths do not agree with its size.
    Malformed,
};

pub const header_size = 144;

const id_offset = 0;
const pubkey_offset = 32;
const sig_offset = 64;
const created_at_offset = 128;
const kind_offset = 136;
const tag_count_offset = 138;
const content_len_offset = 140;

pub fn encodedSize(event: *const Event) EncodeError!usize {
    var size: usize = header_size + event.content.len;
    if (event.tags.len > std.math.maxInt(u16)) return error.TooLarge;
    for (event.tags) |tag| {
        if (tag.len > std.math.maxInt(u16)) return error.TooLarge;
        size += 2;
        for (tag) |field| {
            if (field.len > std.math.maxInt(u32)) return error.TooLarge;
            size += 4 + field.len;
        }
    }
    if (event.content.len > std.math.maxInt(u32)) return error.TooLarge;
    return size;
}

/// Writes `event` into `buffer` and returns how many bytes it used.
pub fn encode(buffer: []u8, event: *const Event) EncodeError!usize {
    const size = try encodedSize(event);
    if (buffer.len < size) return error.BufferTooSmall;

    @memcpy(buffer[id_offset..][0..32], &event.id);
    @memcpy(buffer[pubkey_offset..][0..32], &event.pubkey);
    @memcpy(buffer[sig_offset..][0..64], &event.sig);
    std.mem.writeInt(i64, buffer[created_at_offset..][0..8], event.created_at, .little);
    std.mem.writeInt(u16, buffer[kind_offset..][0..2], event.kind, .little);
    std.mem.writeInt(u16, buffer[tag_count_offset..][0..2], @intCast(event.tags.len), .little);
    std.mem.writeInt(u32, buffer[content_len_offset..][0..4], @intCast(event.content.len), .little);

    var cursor: usize = header_size;
    for (event.tags) |tag| {
        std.mem.writeInt(u16, buffer[cursor..][0..2], @intCast(tag.len), .little);
        cursor += 2;
        for (tag) |field| {
            std.mem.writeInt(u32, buffer[cursor..][0..4], @intCast(field.len), .little);
            cursor += 4;
            @memcpy(buffer[cursor..][0..field.len], field);
            cursor += field.len;
        }
    }
    @memcpy(buffer[cursor..][0..event.content.len], event.content);
    cursor += event.content.len;

    std.debug.assert(cursor == size);
    return cursor;
}

/// Reads a record back. `content` and every tag field alias `bytes`; only the
/// slice structure holding the tags is allocated, so the caller's arena bounds
/// what a query costs while the event bytes stay in the map.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Event {
    if (bytes.len < header_size) return error.Malformed;

    const tag_count = std.mem.readInt(u16, bytes[tag_count_offset..][0..2], .little);
    const content_len = std.mem.readInt(u32, bytes[content_len_offset..][0..4], .little);

    const tags = try allocator.alloc(Tag, tag_count);
    errdefer allocator.free(tags);

    var cursor: usize = header_size;
    for (tags) |*tag| {
        if (cursor + 2 > bytes.len) return error.Malformed;
        const field_count = std.mem.readInt(u16, bytes[cursor..][0..2], .little);
        cursor += 2;

        const fields = try allocator.alloc([]const u8, field_count);
        for (fields) |*field| {
            if (cursor + 4 > bytes.len) return error.Malformed;
            const len = std.mem.readInt(u32, bytes[cursor..][0..4], .little);
            cursor += 4;
            if (cursor + len > bytes.len) return error.Malformed;
            field.* = bytes[cursor..][0..len];
            cursor += len;
        }
        tag.* = fields;
    }

    if (cursor + content_len != bytes.len) return error.Malformed;

    return .{
        .id = bytes[id_offset..][0..32].*,
        .pubkey = bytes[pubkey_offset..][0..32].*,
        .sig = bytes[sig_offset..][0..64].*,
        .created_at = std.mem.readInt(i64, bytes[created_at_offset..][0..8], .little),
        .kind = std.mem.readInt(u16, bytes[kind_offset..][0..2], .little),
        .tags = tags,
        .content = bytes[cursor..][0..content_len],
    };
}

const testing = std.testing;

fn roundTrip(arena: std.mem.Allocator, event: *const Event) !Event {
    const size = try encodedSize(event);
    const buffer = try arena.alloc(u8, size);
    const written = try encode(buffer, event);
    try testing.expectEqual(size, written);
    return decode(arena, buffer[0..written]);
}

fn expectSameEvent(expected: *const Event, actual: Event) !void {
    try testing.expectEqualSlices(u8, &expected.id, &actual.id);
    try testing.expectEqualSlices(u8, &expected.pubkey, &actual.pubkey);
    try testing.expectEqualSlices(u8, &expected.sig, &actual.sig);
    try testing.expectEqual(expected.created_at, actual.created_at);
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqualStrings(expected.content, actual.content);
    try testing.expectEqual(expected.tags.len, actual.tags.len);
    for (expected.tags, actual.tags) |want, got| {
        try testing.expectEqual(want.len, got.len);
        for (want, got) |want_field, got_field| {
            try testing.expectEqualStrings(want_field, got_field);
        }
    }
}

fn testEvent() Event {
    return .{
        .id = [_]u8{0xaa} ** 32,
        .pubkey = [_]u8{0xbb} ** 32,
        .sig = [_]u8{0xcc} ** 64,
        .created_at = 1700000000,
        .kind = 1,
        .tags = &.{},
        .content = "",
    };
}

test "an event with no tags and no content round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const event = testEvent();
    try expectSameEvent(&event, try roundTrip(arena.allocator(), &event));
}

test "tags and content round-trip, including non-ASCII and embedded NUL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Tag{
        &.{ "e", "e" ** 32, "wss://relay.example", "root" },
        &.{ "p", "p" ** 32 },
        &.{"single"},
    };
    var event = testEvent();
    event.tags = &tags;
    event.content = "unicode é, a quote \", a backslash \\, a newline \n and a NUL \x00 byte";

    try expectSameEvent(&event, try roundTrip(arena.allocator(), &event));
}

test "an empty tag and an empty tag field survive the round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Tag{ &.{}, &.{ "d", "" } };
    var event = testEvent();
    event.tags = &tags;

    const decoded = try roundTrip(arena.allocator(), &event);
    try expectSameEvent(&event, decoded);
    try testing.expectEqual(@as(usize, 0), decoded.tags[0].len);
    try testing.expectEqualStrings("", decoded.tags[1][1]);
}

test "created_at before the epoch round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var event = testEvent();
    event.created_at = -1;

    const decoded = try roundTrip(arena.allocator(), &event);
    try testing.expectEqual(@as(i64, -1), decoded.created_at);
}

test "the decoded content and tag fields alias the record rather than copying it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Tag{&.{ "d", "value" }};
    var event = testEvent();
    event.tags = &tags;
    event.content = "borrowed";

    const size = try encodedSize(&event);
    const buffer = try arena.allocator().alloc(u8, size);
    const written = try encode(buffer, &event);
    const decoded = try decode(arena.allocator(), buffer[0..written]);

    const record = buffer[0..written];
    try testing.expect(@intFromPtr(decoded.content.ptr) >= @intFromPtr(record.ptr));
    try testing.expect(@intFromPtr(decoded.content.ptr) < @intFromPtr(record.ptr) + record.len);
    try testing.expect(@intFromPtr(decoded.tags[0][1].ptr) >= @intFromPtr(record.ptr));
    try testing.expect(@intFromPtr(decoded.tags[0][1].ptr) < @intFromPtr(record.ptr) + record.len);
}

test "encode refuses a buffer that is too small" {
    const event = testEvent();
    var buffer: [header_size - 1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encode(&buffer, &event));
}

test "a truncated record is rejected rather than read past" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Tag{&.{ "e", "value" }};
    var event = testEvent();
    event.tags = &tags;
    event.content = "content";

    const size = try encodedSize(&event);
    const buffer = try arena.allocator().alloc(u8, size);
    const written = try encode(buffer, &event);

    try testing.expectError(error.Malformed, decode(arena.allocator(), buffer[0 .. header_size - 1]));
    var cut: usize = header_size;
    while (cut < written) : (cut += 1) {
        try testing.expectError(error.Malformed, decode(arena.allocator(), buffer[0..cut]));
    }
}

test "a record claiming a longer field than it holds is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tags = [_]Tag{&.{"e"}};
    var event = testEvent();
    event.tags = &tags;

    const size = try encodedSize(&event);
    const buffer = try arena.allocator().alloc(u8, size);
    const written = try encode(buffer, &event);

    // The first tag's first field length sits after the header and the tag's
    // own field count.
    std.mem.writeInt(u32, buffer[header_size + 2 ..][0..4], 0xffff, .little);
    try testing.expectError(error.Malformed, decode(arena.allocator(), buffer[0..written]));
}
