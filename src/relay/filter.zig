//! Decoding NIP-01 filters from the JSON a client sends, with the strictness
//! docs/protocol.md#filters requires.
//!
//! This is first-party code rather than an adaptation. `zig-nostr` models a
//! filter and matches events against one, but it only ever *encodes* them: a
//! client library writes filters and reads events, and the relay does the
//! opposite. Decoding is the relay's half of the wire format, and it is the
//! half that touches untrusted input.
//!
//! One rule shapes the whole file: **a malformed field is a malformed filter,
//! not a filter that matches nothing.** Quietly turning
//! `{"authors":["NOT-HEX"]}` into an empty result set tells the client its
//! query ran and found nothing, which is indistinguishable from the truth and
//! is not the truth.

const std = @import("std");
const nostr = @import("nostr");

const diag = @import("diagnostics.zig");

const Filter = nostr.filter.Filter;
const TagFilter = nostr.filter.TagFilter;

pub const Error = error{ MalformedFilter, OutOfMemory };

pub const Reason = enum {
    not_an_object,
    field_wrong_type,
    tag_key_not_a_single_letter,
    value_not_lowercase_hex,
    kind_out_of_range,
    limit_out_of_range,
    timestamp_out_of_range,
};

/// Carries the reason back to the caller, which turns it into the `CLOSED`
/// message docs/protocol.md requires for a subscription it refuses.
pub const Diagnostics = diag.Diagnostics(Reason);

fn malformed(
    diagnostics: *Diagnostics,
    reason: Reason,
    comptime format: []const u8,
    args: anytype,
) Error {
    diagnostics.fail(reason, format, args);
    return error.MalformedFilter;
}

/// Decodes one filter object. Everything the returned filter points at is
/// allocated in `arena`, which is the per-request arena: a filter lives as
/// long as the subscription that owns it, and is copied there by the caller.
pub fn decode(
    arena: std.mem.Allocator,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error!Filter {
    const object = switch (value) {
        .object => |object| object,
        else => return malformed(diagnostics, .not_an_object, "a filter must be a JSON object", .{}),
    };

    var filter: Filter = .{};
    var tags: std.ArrayList(TagFilter) = .empty;

    var fields = object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const field_value = field.value_ptr.*;

        if (std.mem.eql(u8, key, "ids")) {
            filter.ids = try decodeHexArray(arena, key, field_value, diagnostics);
        } else if (std.mem.eql(u8, key, "authors")) {
            filter.authors = try decodeHexArray(arena, key, field_value, diagnostics);
        } else if (std.mem.eql(u8, key, "kinds")) {
            filter.kinds = try decodeKinds(arena, field_value, diagnostics);
        } else if (std.mem.eql(u8, key, "since")) {
            filter.since = try decodeTimestamp(key, field_value, diagnostics);
        } else if (std.mem.eql(u8, key, "until")) {
            filter.until = try decodeTimestamp(key, field_value, diagnostics);
        } else if (std.mem.eql(u8, key, "limit")) {
            filter.limit = try decodeLimit(field_value, diagnostics);
        } else if (key.len != 0 and key[0] == '#') {
            try tags.append(arena, try decodeTagFilter(arena, key, field_value, diagnostics));
        }
        // Anything else is ignored. NIP-01 defines the fields above and later
        // NIPs add their own; refusing a field this relay does not implement
        // would break clients that send it to relays that do.
    }

    if (tags.items.len != 0) filter.tags = tags.items;
    return filter;
}

/// `ids` and `authors`: arrays of 64-character lowercase hex.
fn decodeHexArray(
    arena: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error![]const [32]u8 {
    const array = try expectArray(key, value, diagnostics);

    // An empty array stays an empty array: docs/protocol.md gives it a
    // meaning, and it is "matches nothing" rather than "no constraint".
    const out = try arena.alloc([32]u8, array.items.len);
    for (array.items, out) |item, *target| {
        const text = switch (item) {
            .string => |text| text,
            else => return malformed(
                diagnostics,
                .field_wrong_type,
                "every value in \"{s}\" must be a string",
                .{key},
            ),
        };
        target.* = decodeHex32(text) orelse return malformed(
            diagnostics,
            .value_not_lowercase_hex,
            "\"{s}\" takes 64-character lowercase hex, not \"{s}\"",
            .{ key, truncate(text) },
        );
    }
    return out;
}

fn decodeKinds(
    arena: std.mem.Allocator,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error![]const u16 {
    const array = try expectArray("kinds", value, diagnostics);

    const out = try arena.alloc(u16, array.items.len);
    for (array.items, out) |item, *target| {
        const number = switch (item) {
            .integer => |number| number,
            else => return malformed(
                diagnostics,
                .field_wrong_type,
                "every value in \"kinds\" must be an integer",
                .{},
            ),
        };
        // Never truncated into range: a kind of 65537 silently becoming kind 1
        // would subscribe the client to something it did not ask for.
        if (number < 0 or number > std.math.maxInt(u16)) {
            return malformed(
                diagnostics,
                .kind_out_of_range,
                "kind {d} is outside the range 0 to 65535",
                .{number},
            );
        }
        target.* = @intCast(number);
    }
    return out;
}

fn decodeTimestamp(
    key: []const u8,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error!i64 {
    return switch (value) {
        .integer => |number| number,
        // A number too large for i64 arrives as its own case rather than as an
        // integer, which is the only reason this is distinguishable at all.
        .number_string => malformed(
            diagnostics,
            .timestamp_out_of_range,
            "\"{s}\" is outside the range of a unix timestamp",
            .{key},
        ),
        else => malformed(
            diagnostics,
            .field_wrong_type,
            "\"{s}\" must be an integer number of seconds",
            .{key},
        ),
    };
}

fn decodeLimit(value: std.json.Value, diagnostics: *Diagnostics) Error!u32 {
    const number = switch (value) {
        .integer => |number| number,
        .number_string => return malformed(
            diagnostics,
            .limit_out_of_range,
            "\"limit\" is outside the range of a count",
            .{},
        ),
        else => return malformed(
            diagnostics,
            .field_wrong_type,
            "\"limit\" must be an integer",
            .{},
        ),
    };
    if (number < 0 or number > std.math.maxInt(u32)) {
        return malformed(
            diagnostics,
            .limit_out_of_range,
            "limit {d} is outside the range of a count",
            .{number},
        );
    }
    return @intCast(number);
}

/// `#<letter>`: a single-letter tag name and the values its first field may
/// take.
fn decodeTagFilter(
    arena: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error!TagFilter {
    // `#` names exactly one tag letter. A longer name is refused rather than
    // ignored: ignoring a constraint widens the result set, and answering a
    // narrower question with more events is the failure mode that matters.
    if (key.len != 2 or !std.ascii.isAlphabetic(key[1])) {
        return malformed(
            diagnostics,
            .tag_key_not_a_single_letter,
            "\"{s}\" is not a single-letter tag filter",
            .{truncate(key)},
        );
    }
    const letter = key[1];
    const array = try expectArray(key, value, diagnostics);

    const values = try arena.alloc([]const u8, array.items.len);
    for (array.items, values) |item, *target| {
        const text = switch (item) {
            .string => |text| text,
            else => return malformed(
                diagnostics,
                .field_wrong_type,
                "every value in \"{s}\" must be a string",
                .{key},
            ),
        };
        // `#e` and `#p` address events and pubkeys, so they carry the same hex
        // rule as `ids` and `authors`. Every other letter takes arbitrary text.
        if ((letter == 'e' or letter == 'p') and decodeHex32(text) == null) {
            return malformed(
                diagnostics,
                .value_not_lowercase_hex,
                "\"{s}\" takes 64-character lowercase hex, not \"{s}\"",
                .{ key, truncate(text) },
            );
        }
        target.* = text;
    }
    return .{ .letter = letter, .values = values };
}

fn expectArray(
    key: []const u8,
    value: std.json.Value,
    diagnostics: *Diagnostics,
) Error!std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => malformed(
            diagnostics,
            .field_wrong_type,
            "\"{s}\" must be an array",
            .{key},
        ),
    };
}

/// Exactly 64 lowercase hex characters, per docs/protocol.md. Uppercase is
/// excluded on purpose: an id is the hex of a hash, the network writes it in
/// lowercase, and accepting both spellings means two spellings of the same
/// subscription reaching a store that indexes one of them.
fn decodeHex32(text: []const u8) ?[32]u8 {
    if (text.len != 64) return null;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, index| {
        const high = hexDigit(text[index * 2]) orelse return null;
        const low = hexDigit(text[index * 2 + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return out;
}

fn hexDigit(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        else => null,
    };
}

/// Keeps a client-supplied string from filling the diagnostic message, which
/// would push the part that explains the failure out of the buffer.
fn truncate(text: []const u8) []const u8 {
    return text[0..@min(text.len, 24)];
}

const testing = std.testing;

const hex_a = "aa" ** 32;
const hex_b = "bb" ** 32;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: Diagnostics = .{},

    fn init() Harness {
        return .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn parse(self: *Harness, json_text: []const u8) !Filter {
        const arena = self.arena_state.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
        return decode(arena, value, &self.diagnostics);
    }
};

fn testEvent(
    pubkey_byte: u8,
    kind: u16,
    created_at: i64,
    tags: []const nostr.event.Tag,
) nostr.event.Event {
    return .{
        .id = [_]u8{0x11} ** 32,
        .pubkey = [_]u8{pubkey_byte} ** 32,
        .created_at = created_at,
        .kind = kind,
        .tags = tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

test "an empty filter constrains nothing" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{}");
    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &.{})));
    try testing.expect(filter.matches(testEvent(0xbb, 30023, 999, &.{})));
}

test "ids and authors decode to their 32 bytes" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"ids\":[\"" ++ hex_a ++ "\"],\"authors\":[\"" ++ hex_b ++ "\"]}");
    try testing.expectEqual(@as(usize, 1), filter.ids.?.len);
    try testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 32, &filter.ids.?[0]);
    try testing.expectEqualSlices(u8, &[_]u8{0xbb} ** 32, &filter.authors.?[0]);
}

test "uppercase hex is a malformed filter, not one that matches nothing" {
    var harness = Harness.init();
    defer harness.deinit();

    const upper = "AA" ** 32;
    try testing.expectError(error.MalformedFilter, harness.parse("{\"ids\":[\"" ++ upper ++ "\"]}"));
    try testing.expectEqual(Reason.value_not_lowercase_hex, harness.diagnostics.reason.?);
}

test "hex of the wrong length is malformed" {
    var harness = Harness.init();
    defer harness.deinit();

    try testing.expectError(error.MalformedFilter, harness.parse("{\"authors\":[\"abc\"]}"));
    try testing.expectEqual(Reason.value_not_lowercase_hex, harness.diagnostics.reason.?);
}

test "a value of the wrong type is malformed" {
    var harness = Harness.init();
    defer harness.deinit();

    try testing.expectError(error.MalformedFilter, harness.parse("{\"ids\":[7]}"));
    try testing.expectEqual(Reason.field_wrong_type, harness.diagnostics.reason.?);

    var not_an_array = Harness.init();
    defer not_an_array.deinit();
    try testing.expectError(error.MalformedFilter, not_an_array.parse("{\"ids\":\"" ++ hex_a ++ "\"}"));
    try testing.expectEqual(Reason.field_wrong_type, not_an_array.diagnostics.reason.?);

    var not_an_object = Harness.init();
    defer not_an_object.deinit();
    try testing.expectError(error.MalformedFilter, not_an_object.parse("[]"));
    try testing.expectEqual(Reason.not_an_object, not_an_object.diagnostics.reason.?);
}

test "an empty array matches nothing rather than imposing no constraint" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"kinds\":[]}");
    try testing.expectEqual(@as(usize, 0), filter.kinds.?.len);
    try testing.expect(!filter.matches(testEvent(0xaa, 1, 100, &.{})));
}

test "a kind outside the range a kind can hold is malformed" {
    var harness = Harness.init();
    defer harness.deinit();

    // 65537 truncated into a u16 would be kind 1, subscribing the client to
    // something it never asked for.
    try testing.expectError(error.MalformedFilter, harness.parse("{\"kinds\":[65537]}"));
    try testing.expectEqual(Reason.kind_out_of_range, harness.diagnostics.reason.?);

    var negative = Harness.init();
    defer negative.deinit();
    try testing.expectError(error.MalformedFilter, negative.parse("{\"kinds\":[-1]}"));
    try testing.expectEqual(Reason.kind_out_of_range, negative.diagnostics.reason.?);
}

test "since and until decode, and a string does not" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"since\":100,\"until\":200}");
    try testing.expectEqual(@as(i64, 100), filter.since.?);
    try testing.expectEqual(@as(i64, 200), filter.until.?);

    var wrong = Harness.init();
    defer wrong.deinit();
    try testing.expectError(error.MalformedFilter, wrong.parse("{\"since\":\"100\"}"));
    try testing.expectEqual(Reason.field_wrong_type, wrong.diagnostics.reason.?);
}

test "since and until are inclusive" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"since\":100,\"until\":200}");
    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &.{})));
    try testing.expect(filter.matches(testEvent(0xaa, 1, 200, &.{})));
    try testing.expect(!filter.matches(testEvent(0xaa, 1, 99, &.{})));
    try testing.expect(!filter.matches(testEvent(0xaa, 1, 201, &.{})));
}

test "limit decodes, and a negative limit does not" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"limit\":500}");
    try testing.expectEqual(@as(u32, 500), filter.limit.?);

    var negative = Harness.init();
    defer negative.deinit();
    try testing.expectError(error.MalformedFilter, negative.parse("{\"limit\":-1}"));
    try testing.expectEqual(Reason.limit_out_of_range, negative.diagnostics.reason.?);
}

test "a tag filter matches the tag's first value" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"#t\":[\"zig\"]}");
    try testing.expectEqual(@as(u8, 't'), filter.tags.?[0].letter);

    const matching = [_]nostr.event.Tag{&.{ "t", "zig" }};
    const wrong_position = [_]nostr.event.Tag{&.{ "t", "nostr", "zig" }};
    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &matching)));
    try testing.expect(!filter.matches(testEvent(0xaa, 1, 100, &wrong_position)));
}

test "#e and #p carry the same hex rule as ids and authors" {
    var harness = Harness.init();
    defer harness.deinit();

    _ = try harness.parse("{\"#e\":[\"" ++ hex_a ++ "\"]}");

    var not_hex = Harness.init();
    defer not_hex.deinit();
    try testing.expectError(error.MalformedFilter, not_hex.parse("{\"#p\":[\"someone\"]}"));
    try testing.expectEqual(Reason.value_not_lowercase_hex, not_hex.diagnostics.reason.?);

    // Every other letter takes arbitrary text.
    var arbitrary = Harness.init();
    defer arbitrary.deinit();
    _ = try arbitrary.parse("{\"#t\":[\"not hex at all\"]}");
}

test "a tag key that is not a single letter is malformed" {
    for ([_][]const u8{ "{\"#tag\":[\"x\"]}", "{\"#\":[\"x\"]}", "{\"#1\":[\"x\"]}" }) |input| {
        var harness = Harness.init();
        defer harness.deinit();
        try testing.expectError(error.MalformedFilter, harness.parse(input));
        try testing.expectEqual(Reason.tag_key_not_a_single_letter, harness.diagnostics.reason.?);
    }
}

test "an unknown field is ignored" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"kinds\":[1],\"search\":\"anything\"}");
    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &.{})));
}

test "values within a field are OR-ed and fields are AND-ed" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse(
        "{\"kinds\":[1,7],\"authors\":[\"" ++ hex_a ++ "\"]}",
    );

    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &.{})));
    try testing.expect(filter.matches(testEvent(0xaa, 7, 100, &.{})));
    // Right author, wrong kind, and right kind, wrong author.
    try testing.expect(!filter.matches(testEvent(0xaa, 3, 100, &.{})));
    try testing.expect(!filter.matches(testEvent(0xbb, 1, 100, &.{})));
}

test "several tag filters must all match" {
    var harness = Harness.init();
    defer harness.deinit();

    const filter = try harness.parse("{\"#t\":[\"zig\"],\"#r\":[\"https://example.com\"]}");
    try testing.expectEqual(@as(usize, 2), filter.tags.?.len);

    const both = [_]nostr.event.Tag{ &.{ "t", "zig" }, &.{ "r", "https://example.com" } };
    const only_one = [_]nostr.event.Tag{&.{ "t", "zig" }};
    try testing.expect(filter.matches(testEvent(0xaa, 1, 100, &both)));
    try testing.expect(!filter.matches(testEvent(0xaa, 1, 100, &only_one)));
}
