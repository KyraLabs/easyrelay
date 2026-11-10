const std = @import("std");
const nostr = @import("nostr");

const kinds = @import("kind.zig");
const store = @import("store.zig");
const Error = store.Error;
const PutResult = store.PutResult;
const QueryError = store.QueryError;
const Sink = store.Sink;
const Store = store.Store;

const Event = nostr.event.Event;
const Filter = nostr.filter.Filter;
const Tag = nostr.event.Tag;

pub const Memory = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    lock: std.Io.RwLock = .init,
    order: std.ArrayList(Event),
    ids: std.AutoHashMapUnmanaged([32]u8, void),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Memory {
        return .{ .gpa = gpa, .io = io, .order = .empty, .ids = .empty };
    }

    pub fn deinit(self: *Memory) void {
        for (self.order.items) |event| freeEvent(self.gpa, event);
        self.order.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn store(self: *Memory) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn count(self: *Memory) usize {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        return self.order.items.len;
    }

    const vtable: Store.VTable = .{ .put = putErased, .putBatch = putBatchErased, .query = queryErased };

    fn putErased(ptr: *anyopaque, event: *const Event) Error!PutResult {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        return self.put(event);
    }

    fn putBatchErased(ptr: *anyopaque, events: []const Event, results: []PutResult) Error!void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (events, results) |*event, *result| result.* = try self.insert(event);
    }

    fn queryErased(ptr: *anyopaque, filters: []const Filter, sink: Sink) QueryError!void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        return self.query(filters, sink);
    }

    fn put(self: *Memory, event: *const Event) Error!PutResult {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.insert(event);
    }

    fn insert(self: *Memory, event: *const Event) Error!PutResult {
        std.debug.assert(kinds.classify(event.kind) != .ephemeral);
        if (self.ids.contains(event.id)) return .duplicate;

        const incumbent = self.incumbentIndex(event);
        if (incumbent) |index| {
            if (!kinds.supersedes(event, &self.order.items[index])) return .outdated;
        }

        try self.order.ensureUnusedCapacity(self.gpa, 1);
        try self.ids.ensureUnusedCapacity(self.gpa, 1);

        const owned = try dupeEvent(self.gpa, event);
        if (incumbent) |index| {
            const superseded = self.order.orderedRemove(index);
            std.debug.assert(self.ids.remove(superseded.id));
            freeEvent(self.gpa, superseded);
        }
        self.order.insertAssumeCapacity(self.insertionIndex(event), owned);
        self.ids.putAssumeCapacityNoClobber(owned.id, {});

        std.debug.assert(self.order.items.len == self.ids.count());
        return .stored;
    }

    fn query(self: *Memory, filters: []const Filter, sink: Sink) QueryError!void {
        const remaining = try self.gpa.alloc(u64, filters.len);
        defer self.gpa.free(remaining);
        var open: usize = 0;
        for (filters, remaining) |filter, *left| {
            left.* = filter.limit orelse std.math.maxInt(u64);
            if (left.* != 0) open += 1;
        }

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var matched: std.ArrayList(Event) = .empty;
        {
            self.lock.lockSharedUncancelable(self.io);
            defer self.lock.unlockShared(self.io);

            for (self.order.items) |event| {
                if (open == 0) break;
                var wanted = false;
                for (filters, remaining) |filter, *left| {
                    if (left.* == 0 or !filter.matches(event)) continue;
                    left.* -= 1;
                    if (left.* == 0) open -= 1;
                    wanted = true;
                }
                if (wanted) try matched.append(arena, try dupeEvent(arena, &event));
            }
        }

        for (matched.items) |*event| try sink.emit(event);
    }

    fn incumbentIndex(self: Memory, event: *const Event) ?usize {
        if (kinds.classify(event.kind) == .regular) return null;
        for (self.order.items, 0..) |*stored, index| {
            if (kinds.sameCoordinate(event, stored)) return index;
        }
        return null;
    }

    fn insertionIndex(self: Memory, event: *const Event) usize {
        var lo: usize = 0;
        var hi: usize = self.order.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (isNewer(&self.order.items[mid], event)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

fn isNewer(a: *const Event, b: *const Event) bool {
    if (a.created_at != b.created_at) return a.created_at > b.created_at;
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

fn dupeEvent(gpa: std.mem.Allocator, event: *const Event) Error!Event {
    const tags = try gpa.alloc(Tag, event.tags.len);
    var copied: usize = 0;
    errdefer {
        for (tags[0..copied]) |tag| freeTag(gpa, tag);
        gpa.free(tags);
    }
    for (event.tags, tags) |source, *target| {
        target.* = try dupeTag(gpa, source);
        copied += 1;
    }

    var owned = event.*;
    owned.tags = tags;
    owned.content = try gpa.dupe(u8, event.content);
    return owned;
}

fn dupeTag(gpa: std.mem.Allocator, tag: Tag) Error!Tag {
    const fields = try gpa.alloc([]const u8, tag.len);
    var copied: usize = 0;
    errdefer {
        for (fields[0..copied]) |field| gpa.free(field);
        gpa.free(fields);
    }
    for (tag, fields) |source, *target| {
        target.* = try gpa.dupe(u8, source);
        copied += 1;
    }
    return fields;
}

fn freeEvent(gpa: std.mem.Allocator, event: Event) void {
    for (event.tags) |tag| freeTag(gpa, tag);
    gpa.free(event.tags);
    gpa.free(event.content);
}

fn freeTag(gpa: std.mem.Allocator, tag: Tag) void {
    for (tag) |field| gpa.free(field);
    gpa.free(tag);
}

const testing = std.testing;

fn testEvent(id_byte: u8, created_at: i64, kind: u16) Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0xab} ** 32,
        .created_at = created_at,
        .kind = kind,
        .tags = &.{},
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

const Collector = struct {
    ids: [8][32]u8 = undefined,
    content_bytes: [8][64]u8 = undefined,
    contents: [8][]const u8 = undefined,
    len: usize = 0,
    stop_after: usize = 8,

    fn sink(self: *Collector) Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) Sink.Abort!void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        if (self.len == self.stop_after) return error.Abort;
        self.ids[self.len] = event.id;
        const copy = self.content_bytes[self.len][0..event.content.len];
        @memcpy(copy, event.content);
        self.contents[self.len] = copy;
        self.len += 1;
    }

    fn idAt(self: Collector, index: usize) u8 {
        return self.ids[index][0];
    }
};

test "put stores an event" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    try testing.expectEqual(PutResult.stored, try memory.store().put(&event));
    try testing.expectEqual(@as(usize, 1), memory.count());
}

test "the same id twice is a duplicate and changes nothing" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);
    try testing.expectEqual(PutResult.duplicate, try memory.store().put(&event));
    try testing.expectEqual(@as(usize, 1), memory.count());
}

test "query streams newest first" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(3, 1700000200, 1),
        testEvent(2, 1700000100, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{}}, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
    try testing.expectEqual(@as(u8, 1), collector.idAt(2));
}

test "events sharing a created_at are ordered by ascending id" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(0xcc, 1700000000, 1),
        testEvent(0xaa, 1700000000, 1),
        testEvent(0xbb, 1700000000, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{}}, collector.sink());

    try testing.expectEqual(@as(u8, 0xaa), collector.idAt(0));
    try testing.expectEqual(@as(u8, 0xbb), collector.idAt(1));
    try testing.expectEqual(@as(u8, 0xcc), collector.idAt(2));
}

test "a filter constrains what is emitted" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{ .kinds = &.{7} }}, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}

test "filters are OR-ed with each other" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
        testEvent(3, 1700000200, 30023),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1} }, .{ .kinds = &.{7} } };
    try memory.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
    try testing.expectEqual(@as(u8, 1), collector.idAt(1));
}

test "an event matching several filters is emitted once" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{
        .{ .kinds = &.{1} },
        .{ .authors = &.{[_]u8{0xab} ** 32} },
    };
    try memory.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
}

test "each filter's limit bounds only that filter's matches" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
        testEvent(3, 1700000200, 1),
        testEvent(4, 1700000300, 7),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 1 }, .{ .kinds = &.{7}, .limit = 2 } };
    try memory.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 4), collector.idAt(0));
    try testing.expectEqual(@as(u8, 3), collector.idAt(1));
    try testing.expectEqual(@as(u8, 2), collector.idAt(2));
}

test "a zero limit excludes its filter's matches but not another filter's" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 0 }, .{ .kinds = &.{7}, .limit = 1 } };
    try memory.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}

test "an event two filters select is emitted once and counts against both" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 1 }, .{ .authors = &.{[_]u8{0xab} ** 32}, .limit = 1 } };
    try memory.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}

test "no filters and a zero limit both emit nothing" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);

    var no_filters: Collector = .{};
    try memory.store().query(&.{}, no_filters.sink());
    try testing.expectEqual(@as(usize, 0), no_filters.len);

    var zero_limit: Collector = .{};
    try memory.store().query(&.{.{ .limit = 0 }}, zero_limit.sink());
    try testing.expectEqual(@as(usize, 0), zero_limit.len);
}

test "a sink that aborts stops the query" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(error.Abort, memory.store().query(&.{.{}}, collector.sink()));
    try testing.expectEqual(@as(usize, 1), collector.len);
}

test "the store keeps its own copy of what the event borrows" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const content = try testing.allocator.dupe(u8, "borrowed content");
    const letter = try testing.allocator.dupe(u8, "e");
    const value = try testing.allocator.dupe(u8, "borrowed tag value");
    const fields = try testing.allocator.alloc([]const u8, 2);
    fields[0] = letter;
    fields[1] = value;
    const tags = try testing.allocator.alloc(Tag, 1);
    tags[0] = fields;

    var event = testEvent(1, 1700000000, 1);
    event.content = content;
    event.tags = tags;
    _ = try memory.store().put(&event);

    testing.allocator.free(tags);
    testing.allocator.free(fields);
    testing.allocator.free(value);
    testing.allocator.free(letter);
    testing.allocator.free(content);

    var collector: Collector = .{};
    try memory.store().query(&.{.{ .tags = &.{.{ .letter = 'e', .values = &.{"borrowed tag value"} }} }}, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqualStrings("borrowed content", collector.contents[0]);
}

const ConcurrentWriter = struct {
    store: Store,
    first_id: u8,

    fn run(self: ConcurrentWriter) void {
        for (0..500) |i| {
            var event = testEvent(self.first_id, @intCast(i), 1);
            std.mem.writeInt(u32, event.id[1..5], @intCast(i), .little);
            _ = self.store.put(&event) catch |err| std.debug.panic("put failed: {t}", .{err});
        }
    }
};

const ConcurrentReader = struct {
    store: Store,

    fn run(self: ConcurrentReader) void {
        for (0..200) |_| {
            var collector: Collector = .{};
            self.store.query(&.{.{ .limit = 8 }}, collector.sink()) catch |err| std.debug.panic("query failed: {t}", .{err});
        }
    }
};

test "concurrent puts and queries keep every event" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    var writers: [4]std.Thread = undefined;
    var readers: [2]std.Thread = undefined;
    for (&writers, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, ConcurrentWriter.run, .{ConcurrentWriter{
            .store = memory.store(),
            .first_id = @intCast(index),
        }});
    }
    for (&readers) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ConcurrentReader.run, .{ConcurrentReader{ .store = memory.store() }});
    }
    for (writers) |thread| thread.join();
    for (readers) |thread| thread.join();

    try testing.expectEqual(@as(usize, 2000), memory.count());
}

const Republisher = struct {
    memory: *Memory,
    emitted: usize = 0,

    fn sink(self: *Republisher) Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) Sink.Abort!void {
        const self: *Republisher = @ptrCast(@alignCast(ptr));
        var newer = event.*;
        newer.id[31] ^= 0xff;
        newer.created_at += 1;
        _ = self.memory.store().put(&newer) catch return error.Abort;
        self.emitted += 1;
    }
};

test "a query does not hold the lock while its sink runs" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);

    var republisher: Republisher = .{ .memory = &memory };
    try memory.store().query(&.{.{}}, republisher.sink());

    try testing.expectEqual(@as(usize, 1), republisher.emitted);
    try testing.expectEqual(@as(usize, 2), memory.count());
}

test "a replaceable event supersedes the stored one and an older one is outdated" {
    var memory = Memory.init(testing.allocator, testing.io);
    defer memory.deinit();

    const old = testEvent(1, 1700000000, 0);
    const new = testEvent(2, 1700000100, 0);
    const older = testEvent(3, 1699999999, 0);
    try testing.expectEqual(PutResult.stored, try memory.store().put(&old));
    try testing.expectEqual(PutResult.stored, try memory.store().put(&new));
    try testing.expectEqual(PutResult.outdated, try memory.store().put(&older));
    try testing.expectEqual(PutResult.outdated, try memory.store().put(&old));
    try testing.expectEqual(@as(usize, 1), memory.count());

    var collector: Collector = .{};
    try memory.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}
