const std = @import("std");
const nostr = @import("nostr");

const Filter = nostr.filter.Filter;
const TagFilter = nostr.filter.TagFilter;

pub const Limits = struct {
    max_subscriptions: usize = 20,
    max_limit: usize = 5000,
    default_limit: usize = 500,
    max_held_bytes: usize = 1024 * 1024,
};

pub const Held = struct {
    local_id: ?u64,
    message: []u8,
};

pub const Holding = struct {
    messages: std.ArrayList(Held) = .empty,
    bytes: usize = 0,
    overflowed: bool = false,

    pub fn deinit(self: *Holding, gpa: std.mem.Allocator) void {
        for (self.messages.items) |held| gpa.free(held.message);
        self.messages.deinit(gpa);
        self.* = undefined;
    }
};

pub const Subscription = struct {
    id: []const u8,
    filters: []const Filter,
    /// Live events at or below this local id were visible to the stored phase.
    watermark: u64 = 0,
    holding: ?Holding = null,
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
        for (self.entries.items) |*entry| self.free(entry);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: Registry) usize {
        return self.entries.items.len;
    }

    pub fn items(self: Registry) []Subscription {
        return self.entries.items;
    }

    pub fn hold(self: *Registry, id: []const u8) void {
        const index = self.indexOf(id) orelse return;
        std.debug.assert(self.entries.items[index].holding == null);
        self.entries.items[index].holding = .{};
    }

    pub fn keep(self: *Registry, subscription: *Subscription, local_id: ?u64, message: []const u8) void {
        std.debug.assert(subscription.holding != null);
        const holding = &subscription.holding.?;
        if (holding.overflowed) return;
        if (holding.bytes + message.len > self.limits.max_held_bytes) {
            holding.overflowed = true;
            return;
        }
        const copy = self.gpa.dupe(u8, message) catch {
            holding.overflowed = true;
            return;
        };
        holding.messages.append(self.gpa, .{ .local_id = local_id, .message = copy }) catch {
            self.gpa.free(copy);
            holding.overflowed = true;
            return;
        };
        holding.bytes += message.len;
    }

    pub const Released = union(enum) {
        live,
        held: Holding,
        overflowed,
        gone,
    };

    /// Goes live in the same step that finds nothing held, so no live event slips in between.
    pub fn release(self: *Registry, id: []const u8) Released {
        const index = self.indexOf(id) orelse return .gone;
        const subscription = &self.entries.items[index];
        if (subscription.holding == null) return .live;
        const holding = &subscription.holding.?;
        if (holding.overflowed) return .overflowed;
        if (holding.messages.items.len == 0) {
            holding.deinit(self.gpa);
            subscription.holding = null;
            return .live;
        }
        const taken = holding.*;
        holding.* = .{};
        return .{ .held = taken };
    }

    pub fn setWatermark(self: *Registry, id: []const u8, watermark: u64) void {
        const index = self.indexOf(id) orelse return;
        self.entries.items[index].watermark = watermark;
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
            self.free(&self.entries.items[index]);
            self.entries.items[index] = owned;
            return;
        }
        try self.entries.append(self.gpa, owned);
    }

    pub fn close(self: *Registry, id: []const u8) bool {
        const index = self.indexOf(id) orelse return false;
        self.free(&self.entries.items[index]);
        _ = self.entries.orderedRemove(index);
        return true;
    }

    fn free(self: *Registry, subscription: *Subscription) void {
        if (subscription.holding) |*holding| holding.deinit(self.gpa);
        subscription.arena.deinit();
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

test "a held subscription keeps live events until released, then goes live" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();
    try registry.open("s", &.{});
    registry.hold("s");

    registry.keep(&registry.items()[0], 7, "first");
    var released = registry.release("s");
    try testing.expectEqualStrings("first", released.held.messages.items[0].message);
    try testing.expectEqual(@as(?u64, 7), released.held.messages.items[0].local_id);
    released.held.deinit(testing.allocator);

    registry.keep(&registry.items()[0], null, "second");
    released = registry.release("s");
    try testing.expectEqualStrings("second", released.held.messages.items[0].message);
    released.held.deinit(testing.allocator);

    try testing.expectEqual(Registry.Released.live, registry.release("s"));
    try testing.expect(registry.find("s").?.holding == null);
}

test "holding more than the limit marks the subscription overflowed" {
    var registry = Registry.init(testing.allocator, .{ .max_held_bytes = 8 });
    defer registry.deinit();
    try registry.open("s", &.{});
    registry.hold("s");

    registry.keep(&registry.items()[0], 1, "12345");
    registry.keep(&registry.items()[0], 2, "67890");
    try testing.expectEqual(Registry.Released.overflowed, registry.release("s"));
}

test "closing or replacing a held subscription frees what it held" {
    var registry = Registry.init(testing.allocator, .{});
    defer registry.deinit();
    try registry.open("s", &.{});
    registry.hold("s");
    registry.keep(&registry.items()[0], 1, "held");
    try registry.open("s", &.{});
    registry.hold("s");
    registry.keep(&registry.items()[0], 2, "held again");
    try testing.expect(registry.close("s"));
    try testing.expectEqual(Registry.Released.gone, registry.release("s"));
}
