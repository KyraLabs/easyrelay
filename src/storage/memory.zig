//! The in-memory `Store` backend.
//!
//! It exists for two reasons and neither of them is deployment. It is what
//! Phase 1 runs on while the LMDB backend is still Phase 2 work, and it is
//! kept permanently afterwards as the differential oracle the property tests
//! compare the indexed store against: two implementations of one interface is
//! what makes an abstraction leak visible immediately
//! (docs/adr/0008-store-abstraction-boundary.md).
//!
//! It is a sorted array and a hash map, and it is not tuned. Insert is a
//! binary search and a memmove; that is the wrong shape for a relay under
//! load and the right shape for something whose answers have to be obviously
//! correct, because it is what the real backend is checked against.
//!
//! Kind semantics — replaceable, ephemeral, addressable — are Phase 2. Every
//! event stored here is stored as a regular event.

const std = @import("std");
const nostr = @import("nostr");

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
    /// Stored events, newest first, each one owned by this store.
    ///
    /// Kept in order on insert rather than sorted per query, because that is
    /// what lets `query` stream: it walks from the front and stops at `limit`,
    /// allocating nothing and holding nothing.
    order: std.ArrayList(Event),
    /// The ids in `order`, for duplicate detection without a scan.
    ids: std.AutoHashMapUnmanaged([32]u8, void),

    pub fn init(gpa: std.mem.Allocator) Memory {
        return .{ .gpa = gpa, .order = .empty, .ids = .empty };
    }

    pub fn deinit(self: *Memory) void {
        for (self.order.items) |event| freeEvent(self.gpa, event);
        self.order.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        self.* = undefined;
    }

    /// The `Store` interface over this backend. The returned value borrows
    /// `self`, which must outlive it.
    pub fn store(self: *Memory) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// How many events are stored.
    pub fn count(self: Memory) usize {
        return self.order.items.len;
    }

    const vtable: Store.VTable = .{ .put = putErased, .query = queryErased };

    fn putErased(ptr: *anyopaque, event: *const Event) Error!PutResult {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        return self.put(event);
    }

    fn queryErased(
        ptr: *anyopaque,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) QueryError!void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        return self.query(filters, limit, sink);
    }

    pub fn put(self: *Memory, event: *const Event) Error!PutResult {
        if (self.ids.contains(event.id)) return .duplicate;

        // Reserve both slots before copying, so a failure leaves the store
        // exactly as it was rather than holding an event no index can find.
        try self.order.ensureUnusedCapacity(self.gpa, 1);
        try self.ids.ensureUnusedCapacity(self.gpa, 1);

        const owned = try dupeEvent(self.gpa, event);
        self.order.insertAssumeCapacity(self.insertionIndex(event), owned);
        self.ids.putAssumeCapacityNoClobber(owned.id, {});

        std.debug.assert(self.order.items.len == self.ids.count());
        return .stored;
    }

    pub fn query(
        self: *Memory,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) QueryError!void {
        var emitted: usize = 0;
        for (self.order.items) |*event| {
            if (emitted == limit) break;
            if (!matchesAny(filters, event)) continue;
            try sink.emit(event);
            emitted += 1;
        }
        std.debug.assert(emitted <= limit);
    }

    /// Where `event` belongs in `order`, by binary search.
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

/// The order docs/protocol.md requires of every backend: `created_at`
/// descending, ties broken by the lexicographically smaller id first.
fn isNewer(a: *const Event, b: *const Event) bool {
    if (a.created_at != b.created_at) return a.created_at > b.created_at;
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

/// Filters are OR-ed with each other; the fields within one are AND-ed by
/// `Filter.matches`. An empty filter array constrains nothing into existence:
/// it matches no event, which is not the same as the empty filter `{}`.
fn matchesAny(filters: []const Filter, event: *const Event) bool {
    for (filters) |filter| {
        if (filter.matches(event.*)) return true;
    }
    return false;
}

/// Copies everything `event` borrows. The caller's per-request arena is reset
/// as soon as the message is answered, so a stored event that pointed into it
/// would be a use-after-free on the next query.
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

/// Records what a query emitted, in order. The slices it keeps borrow the
/// store, which outlives every assertion made against them here; a sink with
/// a life of its own would have to copy (see `store.Sink`).
const Collector = struct {
    ids: [8][32]u8 = undefined,
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
        self.contents[self.len] = event.content;
        self.len += 1;
    }

    fn idAt(self: Collector, index: usize) u8 {
        return self.ids[index][0];
    }
};

test "put stores an event" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    try testing.expectEqual(PutResult.stored, try memory.store().put(&event));
    try testing.expectEqual(@as(usize, 1), memory.count());
}

test "the same id twice is a duplicate and changes nothing" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);
    try testing.expectEqual(PutResult.duplicate, try memory.store().put(&event));
    try testing.expectEqual(@as(usize, 1), memory.count());
}

test "query streams newest first" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    // Inserted oldest, newest, middle, so that insertion order cannot be
    // mistaken for the answer.
    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(3, 1700000200, 1),
        testEvent(2, 1700000100, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
    try testing.expectEqual(@as(u8, 1), collector.idAt(2));
}

test "events sharing a created_at are ordered by ascending id" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    for ([_]Event{
        testEvent(0xcc, 1700000000, 1),
        testEvent(0xaa, 1700000000, 1),
        testEvent(0xbb, 1700000000, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(u8, 0xaa), collector.idAt(0));
    try testing.expectEqual(@as(u8, 0xbb), collector.idAt(1));
    try testing.expectEqual(@as(u8, 0xcc), collector.idAt(2));
}

test "a filter constrains what is emitted" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    try memory.store().query(&.{.{ .kinds = &.{7} }}, 10, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}

test "filters are OR-ed with each other" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
        testEvent(3, 1700000200, 30023),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1} }, .{ .kinds = &.{7} } };
    try memory.store().query(&filters, 10, collector.sink());

    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
    try testing.expectEqual(@as(u8, 1), collector.idAt(1));
}

test "an event matching several filters is emitted once" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{
        .{ .kinds = &.{1} },
        .{ .authors = &.{[_]u8{0xab} ** 32} },
    };
    try memory.store().query(&filters, 10, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
}

test "limit bounds the stored phase across the whole merge" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 7),
        testEvent(3, 1700000200, 1),
    }) |event| _ = try memory.store().put(&event);

    // Two filters, three matching events, and a limit of two: the answer is
    // the two globally newest, not two per filter.
    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1} }, .{ .kinds = &.{7} } };
    try memory.store().query(&filters, 2, collector.sink());

    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
}

test "no filters and a zero limit both emit nothing" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    const event = testEvent(1, 1700000000, 1);
    _ = try memory.store().put(&event);

    var no_filters: Collector = .{};
    try memory.store().query(&.{}, 10, no_filters.sink());
    try testing.expectEqual(@as(usize, 0), no_filters.len);

    var zero_limit: Collector = .{};
    try memory.store().query(&.{.{}}, 0, zero_limit.sink());
    try testing.expectEqual(@as(usize, 0), zero_limit.len);
}

test "a sink that aborts stops the query" {
    var memory = Memory.init(testing.allocator);
    defer memory.deinit();

    for ([_]Event{
        testEvent(1, 1700000000, 1),
        testEvent(2, 1700000100, 1),
    }) |event| _ = try memory.store().put(&event);

    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(error.Abort, memory.store().query(&.{.{}}, 10, collector.sink()));
    try testing.expectEqual(@as(usize, 1), collector.len);
}

test "the store keeps its own copy of what the event borrows" {
    var memory = Memory.init(testing.allocator);
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

    // Everything the event pointed at is gone before the query runs, which is
    // what a per-request arena reset looks like from the store's side.
    testing.allocator.free(tags);
    testing.allocator.free(fields);
    testing.allocator.free(value);
    testing.allocator.free(letter);
    testing.allocator.free(content);

    var collector: Collector = .{};
    try memory.store().query(&.{.{ .tags = &.{.{ .letter = 'e', .values = &.{"borrowed tag value"} }} }}, 10, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqualStrings("borrowed content", collector.contents[0]);
}
