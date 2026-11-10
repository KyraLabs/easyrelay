const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Every query index key ends with this, so cursors over different indexes merge in one order.
pub const suffix_len = 40;
pub const Suffix = [suffix_len]u8;
pub const max_key_len = 34 + suffix_len;

pub const Index = enum {
    by_created_at,
    by_author,
    by_kind,
    by_author_kind,
    by_tag,

    pub fn name(self: Index) [*:0]const u8 {
        return switch (self) {
            inline else => |tag| @tagName(tag),
        };
    }
};

/// Sign-flipped and inverted so a forward walk yields newest first, ties by ascending id.
pub fn descendingTime(created_at: i64) [8]u8 {
    const biased: u64 = @as(u64, @bitCast(created_at)) ^ (@as(u64, 1) << 63);
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, ~biased, .big);
    return key;
}

pub fn suffix(created_at: i64, id: *const [32]u8) Suffix {
    var key: Suffix = undefined;
    key[0..8].* = descendingTime(created_at);
    key[8..40].* = id.*;
    return key;
}

/// A key prefix for one index, at most 34 bytes.
pub const Prefix = struct {
    bytes: [34]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Prefix) []const u8 {
        return self.bytes[0..self.len];
    }

    fn append(self: *Prefix, data: []const u8) void {
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn none() Prefix {
        return .{};
    }

    pub fn author(pubkey: *const [32]u8) Prefix {
        var prefix: Prefix = .{};
        prefix.append(pubkey);
        return prefix;
    }

    pub fn kind(value: u16) Prefix {
        var prefix: Prefix = .{};
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        prefix.append(&bytes);
        return prefix;
    }

    pub fn authorKind(pubkey: *const [32]u8, value: u16) Prefix {
        var prefix = author(pubkey);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        prefix.append(&bytes);
        return prefix;
    }

    /// The value is hashed because LMDB caps a key at 511 bytes.
    pub fn tag(letter: u8, value: []const u8) Prefix {
        var prefix: Prefix = .{};
        prefix.append(&.{letter});
        var digest: [32]u8 = undefined;
        Sha256.hash(value, &digest, .{});
        prefix.append(&digest);
        return prefix;
    }
};

pub const Key = struct {
    bytes: [max_key_len]u8 = undefined,
    len: usize = 0,

    pub fn init(prefix: Prefix, tail: *const Suffix) Key {
        var key: Key = .{ .len = prefix.len + suffix_len };
        @memcpy(key.bytes[0..prefix.len], prefix.slice());
        key.bytes[prefix.len..][0..suffix_len].* = tail.*;
        return key;
    }

    pub fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Calls `visitor.entry(index, key)` once per query index entry `event` owns.
pub fn forEachEntry(event: *const Event, visitor: anytype) !void {
    const tail = suffix(event.created_at, &event.id);
    try visitor.entry(.by_created_at, Key.init(.none(), &tail));
    try visitor.entry(.by_author, Key.init(.author(&event.pubkey), &tail));
    try visitor.entry(.by_kind, Key.init(.kind(event.kind), &tail));
    try visitor.entry(.by_author_kind, Key.init(.authorKind(&event.pubkey, event.kind), &tail));
    for (event.tags, 0..) |tag, position| {
        if (!isIndexedTag(tag)) continue;
        if (repeatsEarlierTag(event.tags[0..position], tag)) continue;
        try visitor.entry(.by_tag, Key.init(.tag(tag[0][0], tag[1]), &tail));
    }
}

fn isIndexedTag(tag: nostr.event.Tag) bool {
    return tag.len >= 2 and tag[0].len == 1;
}

fn repeatsEarlierTag(earlier: []const nostr.event.Tag, tag: nostr.event.Tag) bool {
    for (earlier) |other| {
        if (!isIndexedTag(other)) continue;
        if (other[0][0] == tag[0][0] and std.mem.eql(u8, other[1], tag[1])) return true;
    }
    return false;
}

const testing = std.testing;

test "the suffix orders newest first and ties by ascending id" {
    const a = [_]u8{0x01} ** 32;
    const b = [_]u8{0x02} ** 32;
    try testing.expect(std.mem.order(u8, &suffix(200, &b), &suffix(100, &a)) == .lt);
    try testing.expect(std.mem.order(u8, &suffix(100, &a), &suffix(100, &b)) == .lt);
    try testing.expect(std.mem.order(u8, &suffix(0, &a), &suffix(-1, &a)) == .lt);
}

const Recorder = struct {
    counts: std.EnumArray(Index, usize) = .initFill(0),

    pub fn entry(self: *Recorder, which: Index, key: Key) !void {
        try testing.expect(key.len >= suffix_len);
        self.counts.getPtr(which).* += 1;
    }
};

test "single-letter tags with a value are indexed once per distinct value" {
    const event: Event = .{
        .id = [_]u8{1} ** 32,
        .pubkey = [_]u8{2} ** 32,
        .created_at = 1,
        .kind = 1,
        .tags = &.{ &.{ "e", "x" }, &.{ "e", "x" }, &.{ "e", "y" }, &.{"p"}, &.{ "title", "z" }, &.{ "t", "x" } },
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    var recorder: Recorder = .{};
    try forEachEntry(&event, &recorder);
    try testing.expectEqual(@as(usize, 1), recorder.counts.get(.by_created_at));
    try testing.expectEqual(@as(usize, 1), recorder.counts.get(.by_author_kind));
    try testing.expectEqual(@as(usize, 3), recorder.counts.get(.by_tag));
}
