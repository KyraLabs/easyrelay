const std = @import("std");
const nostr = @import("nostr");

const Filter = nostr.filter.Filter;
const TagFilter = nostr.filter.TagFilter;

pub const Limits = struct {
    max_subscriptions: usize = 20,
    max_limit: usize = 5000,
    default_limit: usize = 500,
};

pub const Subscription = struct {
    id: []const u8,
    filters: []const Filter,
    arena: std.heap.ArenaAllocator,
};

pub const Error = error{
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

        if (existing) |index| {
            self.entries.items[index].arena.deinit();
            self.entries.items[index] = owned;
            return;
        }
        try self.entries.append(self.gpa, owned);
    }

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

pub fn resolveLimits(arena: std.mem.Allocator, filters: []const Filter, limits: Limits) error{OutOfMemory}![]const Filter {
    const cap = @min(limits.max_limit, std.math.maxInt(u32));
    const resolved = try arena.dupe(Filter, filters);
    for (resolved) |*filter| {
        const requested: usize = filter.limit orelse limits.default_limit;
        filter.limit = @intCast(@min(requested, cap));
    }
    return resolved;
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

test "each filter's limit is defaulted and capped on its own" {
    const limits = Limits{ .max_limit = 100, .default_limit = 20 };
    const filters = [_]Filter{ .{}, .{ .limit = 10 }, .{ .limit = 5000 }, .{ .limit = 0 } };

    const resolved = try resolveLimits(testing.allocator, &filters, limits);
    defer testing.allocator.free(resolved);

    try testing.expectEqual(@as(?u32, 20), resolved[0].limit);
    try testing.expectEqual(@as(?u32, 10), resolved[1].limit);
    try testing.expectEqual(@as(?u32, 100), resolved[2].limit);
    try testing.expectEqual(@as(?u32, 0), resolved[3].limit);
    try testing.expectEqual(@as(?u32, null), filters[0].limit);
}

test "a replacement that cannot be built leaves the old subscription serving" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try registry.open("sub-1", &[_]Filter{try testFilter(arena.allocator(), 1, "original")});

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    registry.gpa = failing.allocator();
    const replacement = [_]Filter{try testFilter(arena.allocator(), 7, "replacement")};
    try testing.expectError(error.OutOfMemory, registry.open("sub-1", &replacement));
    registry.gpa = testing.allocator;

    const surviving = registry.find("sub-1").?;
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(u16, 1), surviving.filters[0].kinds.?[0]);
    try testing.expectEqualStrings("original", surviving.filters[0].tags.?[0].values[0]);
}
