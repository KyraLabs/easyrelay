const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;

/// Admission rules by author and by kind, with lists sorted for binary search.
pub const Policy = struct {
    allowed_pubkeys: ?[]const [32]u8 = null,
    blocked_pubkeys: []const [32]u8 = &.{},
    allowed_kinds: ?[]const u16 = null,
    blocked_kinds: []const u16 = &.{},
    auth_required_for_write: bool = false,
    auth_required_for_read: bool = false,

    pub const Lists = struct {
        allowed_pubkeys: ?[]const []const u8 = null,
        blocked_pubkeys: []const []const u8 = &.{},
        allowed_kinds: ?[]const u16 = null,
        blocked_kinds: []const u16 = &.{},
        auth_required_for_write: bool = false,
        auth_required_for_read: bool = false,
    };

    /// Pubkeys are hex, already validated by the configuration. Everything is allocated in `arena`.
    pub fn init(arena: std.mem.Allocator, lists: Lists) error{ OutOfMemory, InvalidPubkey }!Policy {
        return .{
            .allowed_pubkeys = if (lists.allowed_pubkeys) |hex| try decodeSorted(arena, hex) else null,
            .blocked_pubkeys = try decodeSorted(arena, lists.blocked_pubkeys),
            .allowed_kinds = if (lists.allowed_kinds) |kinds| try sortedKinds(arena, kinds) else null,
            .blocked_kinds = try sortedKinds(arena, lists.blocked_kinds),
            .auth_required_for_write = lists.auth_required_for_write,
            .auth_required_for_read = lists.auth_required_for_read,
        };
    }

    /// Null admits the event; otherwise the reason it is refused, to follow `blocked:`.
    pub fn refusal(self: Policy, event: *const Event) ?[]const u8 {
        if (containsPubkey(self.blocked_pubkeys, &event.pubkey)) return "this author may not publish here";
        if (self.allowed_pubkeys) |allowed| if (!containsPubkey(allowed, &event.pubkey)) return "this relay accepts events only from listed authors";
        if (containsKind(self.blocked_kinds, event.kind)) return "this kind is not accepted here";
        if (self.allowed_kinds) |allowed| if (!containsKind(allowed, event.kind)) return "this relay accepts only listed kinds";
        return null;
    }
};

fn decodeSorted(arena: std.mem.Allocator, hex: []const []const u8) error{ OutOfMemory, InvalidPubkey }![]const [32]u8 {
    const keys = try arena.alloc([32]u8, hex.len);
    for (hex, keys) |text, *key| {
        if (text.len != 64) return error.InvalidPubkey;
        _ = std.fmt.hexToBytes(key, text) catch return error.InvalidPubkey;
    }
    std.mem.sort([32]u8, keys, {}, pubkeyLessThan);
    return keys;
}

fn sortedKinds(arena: std.mem.Allocator, kinds: []const u16) error{OutOfMemory}![]const u16 {
    const sorted = try arena.dupe(u16, kinds);
    std.mem.sort(u16, sorted, {}, std.sort.asc(u16));
    return sorted;
}

fn pubkeyLessThan(_: void, a: [32]u8, b: [32]u8) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn pubkeyOrder(key: *const [32]u8, item: [32]u8) std.math.Order {
    return std.mem.order(u8, key, &item);
}

fn kindOrder(key: u16, item: u16) std.math.Order {
    return std.math.order(key, item);
}

fn containsPubkey(sorted: []const [32]u8, pubkey: *const [32]u8) bool {
    return std.sort.binarySearch([32]u8, sorted, pubkey, pubkeyOrder) != null;
}

fn containsKind(sorted: []const u16, kind: u16) bool {
    return std.sort.binarySearch(u16, sorted, kind, kindOrder) != null;
}

const testing = std.testing;

fn eventBy(pubkey_byte: u8, kind: u16) Event {
    return .{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{pubkey_byte} ** 32,
        .created_at = 0,
        .kind = kind,
        .tags = &.{},
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

test "with no lists, everything is admitted" {
    const policy: Policy = .{};
    try testing.expectEqual(@as(?[]const u8, null), policy.refusal(&eventBy(1, 1)));
}

test "a blocked author is refused and an allow list admits only its members" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const policy = try Policy.init(arena_state.allocator(), .{
        .allowed_pubkeys = &.{ "03" ** 32, "01" ** 32 },
        .blocked_pubkeys = &.{"02" ** 32},
    });
    try testing.expectEqual(@as(?[]const u8, null), policy.refusal(&eventBy(1, 1)));
    try testing.expectEqual(@as(?[]const u8, null), policy.refusal(&eventBy(3, 1)));
    try testing.expect(policy.refusal(&eventBy(2, 1)) != null);
    try testing.expect(policy.refusal(&eventBy(4, 1)) != null);
}

test "kinds are refused by the deny list and filtered by the allow list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const policy = try Policy.init(arena_state.allocator(), .{ .allowed_kinds = &.{ 7, 1, 30023 }, .blocked_kinds = &.{4} });
    try testing.expectEqual(@as(?[]const u8, null), policy.refusal(&eventBy(1, 30023)));
    try testing.expect(policy.refusal(&eventBy(1, 4)) != null);
    try testing.expect(policy.refusal(&eventBy(1, 2)) != null);
}
