const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;

pub const Class = enum { regular, replaceable, ephemeral, addressable };

pub fn classify(kind: u16) Class {
    return switch (kind) {
        0, 3, 10000...19999 => .replaceable,
        20000...29999 => .ephemeral,
        30000...39999 => .addressable,
        else => .regular,
    };
}

/// A missing `d` tag and one without a value both address the empty string.
pub fn dValue(event: *const Event) []const u8 {
    for (event.tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "d")) continue;
        return if (tag.len > 1) tag[1] else "";
    }
    return "";
}

/// Whether `candidate` beats `incumbent` for the same coordinate.
pub fn supersedes(candidate: *const Event, incumbent: *const Event) bool {
    if (candidate.created_at != incumbent.created_at) return candidate.created_at > incumbent.created_at;
    return std.mem.order(u8, &candidate.id, &incumbent.id) == .lt;
}

/// Whether `a` and `b` occupy the same replaceable or addressable slot.
pub fn sameCoordinate(a: *const Event, b: *const Event) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, &a.pubkey, &b.pubkey)) return false;
    return switch (classify(a.kind)) {
        .replaceable => true,
        .addressable => std.mem.eql(u8, dValue(a), dValue(b)),
        .regular, .ephemeral => false,
    };
}

const testing = std.testing;

test "kinds classify by the NIP-01 ranges" {
    for ([_]u16{ 1, 2, 4, 44, 1000, 9999, 45, 999, 40000, 65535 }) |kind| {
        try testing.expectEqual(Class.regular, classify(kind));
    }
    for ([_]u16{ 0, 3, 10000, 19999 }) |kind| try testing.expectEqual(Class.replaceable, classify(kind));
    for ([_]u16{ 20000, 29999 }) |kind| try testing.expectEqual(Class.ephemeral, classify(kind));
    for ([_]u16{ 30000, 39999 }) |kind| try testing.expectEqual(Class.addressable, classify(kind));
}

fn eventWith(tags: []const nostr.event.Tag) Event {
    return .{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0} ** 32,
        .created_at = 0,
        .kind = 30000,
        .tags = tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

test "an absent d tag, a bare d tag and an empty d value are the same coordinate" {
    const absent = eventWith(&.{});
    const bare = eventWith(&.{&.{"d"}});
    const empty = eventWith(&.{&.{ "d", "" }});
    const named = eventWith(&.{ &.{ "t", "x" }, &.{ "d", "slot" }, &.{ "d", "other" } });

    try testing.expectEqualStrings("", dValue(&absent));
    try testing.expectEqualStrings("", dValue(&bare));
    try testing.expectEqualStrings("", dValue(&empty));
    try testing.expectEqualStrings("slot", dValue(&named));
    try testing.expect(sameCoordinate(&absent, &bare) and sameCoordinate(&bare, &empty));
    try testing.expect(!sameCoordinate(&absent, &named));
}

test "the later created_at wins, and a tie goes to the lexically smaller id" {
    var older = eventWith(&.{});
    var newer = eventWith(&.{});
    newer.created_at = 1;
    try testing.expect(supersedes(&newer, &older));
    try testing.expect(!supersedes(&older, &newer));

    older.id[0] = 0x02;
    var smaller = older;
    smaller.id[0] = 0x01;
    try testing.expect(supersedes(&smaller, &older));
    try testing.expect(!supersedes(&older, &smaller));
    try testing.expect(!supersedes(&older, &older));
}
