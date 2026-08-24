//! The subscriptions one connection has open.
//!
//! A subscription outlives the message that opened it, and the filters that
//! `REQ` arrived with point into the per-message arena, which is reset as soon
//! as the message is answered. So opening one copies everything it borrows.
//!
//! Each subscription owns an arena holding its id and its filters, which makes
//! closing or replacing one a single `deinit` rather than a walk over a tree of
//! slices. Replacing is a real operation and not a rarity — a client scrolling
//! a feed reissues the same subscription id with a new `until` — so the memory
//! it holds has to come back, which is why this is not one arena per
//! connection.

const std = @import("std");
const nostr = @import("nostr");

const Filter = nostr.filter.Filter;
const TagFilter = nostr.filter.TagFilter;

/// From the `limits` section of docs/configuration.md, spelled as it spells
/// them.
pub const Limits = struct {
    max_subscriptions: usize = 20,
    max_limit: usize = 5000,
    default_limit: usize = 500,
};

pub const Subscription = struct {
    id: []const u8,
    filters: []const Filter,
    /// Owns `id` and everything `filters` points at.
    arena: std.heap.ArenaAllocator,
};

pub const Error = error{
    /// The connection already holds as many subscriptions as it may.
    TooMany,
    OutOfMemory,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    entries: std.ArrayList(Subscription),

    pub fn init(gpa: std.mem.Allocator, limits: Limits) Registry {
        return .{ .gpa = gpa, .limits = limits, .entries = .empty };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| entry.arena.deinit();
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: Registry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: Registry) []const Subscription {
        return self.entries.items;
    }

    pub fn find(self: Registry, id: []const u8) ?*const Subscription {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    /// Opens a subscription, replacing one with the same id. Replacing does not
    /// count against the limit, because a `REQ` reusing an open id is a
    /// replacement and not a second subscription (docs/protocol.md).
    pub fn open(self: *Registry, id: []const u8, filters: []const Filter) Error!void {
        const existing = self.indexOf(id);
        if (existing == null and self.entries.items.len >= self.limits.max_subscriptions) {
            return error.TooMany;
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const owned: Subscription = .{
            .id = try arena.allocator().dupe(u8, id),
            .filters = try copyFilters(arena.allocator(), filters),
            .arena = arena,
        };

        // Only now that the copy exists does the incumbent go: a failed
        // replacement must leave the old subscription serving.
        if (existing) |index| {
            self.entries.items[index].arena.deinit();
            self.entries.items[index] = owned;
            return;
        }
        try self.entries.append(self.gpa, owned);
    }

    /// Returns whether there was one to close.
    pub fn close(self: *Registry, id: []const u8) bool {
        const index = self.indexOf(id) orelse return false;
        self.entries.items[index].arena.deinit();
        _ = self.entries.orderedRemove(index);
        return true;
    }

    fn indexOf(self: Registry, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }
};

fn copyFilters(arena: std.mem.Allocator, filters: []const Filter) Error![]const Filter {
    const copies = try arena.alloc(Filter, filters.len);
    for (filters, copies) |source, *target| target.* = try copyFilter(arena, source);
    return copies;
}

fn copyFilter(arena: std.mem.Allocator, filter: Filter) Error!Filter {
    var copy = filter;
    if (filter.ids) |ids| copy.ids = try arena.dupe([32]u8, ids);
    if (filter.authors) |authors| copy.authors = try arena.dupe([32]u8, authors);
    if (filter.kinds) |kinds| copy.kinds = try arena.dupe(u16, kinds);
    if (filter.tags) |tags| {
        const tag_copies = try arena.alloc(TagFilter, tags.len);
        for (tags, tag_copies) |source, *target| {
            const values = try arena.alloc([]const u8, source.values.len);
            for (source.values, values) |value, *value_target| {
                value_target.* = try arena.dupe(u8, value);
            }
            target.* = .{ .letter = source.letter, .values = values };
        }
        copy.tags = tag_copies;
    }
    return copy;
}

/// The bound the store applies to a `REQ`'s stored phase.
///
/// A `REQ` carries several filters, each free to name its own `limit`, while
/// the bound applies across the merged result (docs/protocol.md). The largest
/// request wins, so that no filter is served fewer events than it asked for,
/// and `max_limit` caps the answer.
pub fn resolveLimit(filters: []const Filter, limits: Limits) usize {
    var requested: ?usize = null;
    for (filters) |filter| {
        const filter_limit = filter.limit orelse continue;
        requested = @max(requested orelse 0, filter_limit);
    }
    return @min(requested orelse limits.default_limit, limits.max_limit);
}

const testing = std.testing;

fn testFilter(arena: std.mem.Allocator, kind: u16, tag_value: []const u8) !Filter {
    const values = try arena.alloc([]const u8, 1);
    values[0] = try arena.dupe(u8, tag_value);
    const tags = try arena.alloc(TagFilter, 1);
    tags[0] = .{ .letter = 't', .values = values };

    const kinds = try arena.alloc(u16, 1);
    kinds[0] = kind;

    return .{ .kinds = kinds, .tags = tags };
}

test "opening a subscription copies everything the filters borrow" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();

    // The filters live in an arena that is thrown away straight after, the way
    // a per-message arena is reset as soon as the message is answered.
    {
        var message_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer message_arena.deinit();

        const filters = [_]Filter{try testFilter(message_arena.allocator(), 7, "zig")};
        try registry.open("sub-1", &filters);
    }

    const kept = registry.find("sub-1").?;
    try testing.expectEqual(@as(u16, 7), kept.filters[0].kinds.?[0]);
    try testing.expectEqualStrings("zig", kept.filters[0].tags.?[0].values[0]);
    try testing.expectEqualStrings("sub-1", kept.id);
}

test "reusing an id replaces rather than adds" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try registry.open("sub-1", &[_]Filter{try testFilter(arena.allocator(), 1, "a")});
    try registry.open("sub-1", &[_]Filter{try testFilter(arena.allocator(), 7, "b")});

    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(u16, 7), registry.find("sub-1").?.filters[0].kinds.?[0]);
}

test "the limit counts open subscriptions, and a replacement is not a new one" {
    var registry = Registry.init(testing.allocator, .{ .max_subscriptions = 2 });
    defer registry.deinit();

    try registry.open("a", &.{});
    try registry.open("b", &.{});
    try registry.open("b", &.{});
    try testing.expectError(error.TooMany, registry.open("c", &.{}));
    try testing.expectEqual(@as(usize, 2), registry.count());
}

test "closing frees the subscription and reports whether there was one" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();

    try registry.open("sub-1", &.{});
    try testing.expect(registry.close("sub-1"));
    try testing.expect(!registry.close("sub-1"));
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "the stored bound is the largest a filter asked for, capped by max_limit" {
    const limits = Limits{ .max_limit = 100, .default_limit = 20 };

    try testing.expectEqual(@as(usize, 20), resolveLimit(&.{.{}}, limits));
    try testing.expectEqual(@as(usize, 20), resolveLimit(&.{}, limits));
    try testing.expectEqual(@as(usize, 50), resolveLimit(&.{ .{ .limit = 10 }, .{ .limit = 50 } }, limits));
    try testing.expectEqual(@as(usize, 100), resolveLimit(&.{.{ .limit = 5000 }}, limits));
    try testing.expectEqual(@as(usize, 0), resolveLimit(&.{.{ .limit = 0 }}, limits));
}
