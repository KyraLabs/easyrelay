const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;
const Filter = nostr.filter.Filter;

pub const Error = error{
    OutOfMemory,
    Backend,
};

pub const QueryError = Error || Sink.Abort;

pub const PutResult = enum {
    stored,
    duplicate,
    /// A replaceable or addressable event lost the tie-break to the one already stored.
    outdated,
};

/// The emitted event borrows the store's memory and is valid only until `emit` returns.
pub const Sink = struct {
    ptr: *anyopaque,
    emitFn: *const fn (ptr: *anyopaque, event: *const Event) Abort!void,

    pub const Abort = error{Abort};

    pub fn emit(self: Sink, event: *const Event) Abort!void {
        return self.emitFn(self.ptr, event);
    }
};

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, event: *const Event) Error!PutResult,
        query: *const fn (ptr: *anyopaque, filters: []const Filter, sink: Sink) QueryError!void,
    };

    /// Ephemeral events must not be passed; they are never stored.
    pub fn put(self: Store, event: *const Event) Error!PutResult {
        return self.vtable.put(self.ptr, event);
    }

    /// Union of each filter's `limit` newest matches, newest first; a null `limit` is unbounded.
    pub fn query(self: Store, filters: []const Filter, sink: Sink) QueryError!void {
        return self.vtable.query(self.ptr, filters, sink);
    }
};

const testing = std.testing;

const StubStore = struct {
    put_result: PutResult = .stored,
    last_put: ?*const Event = null,
    events: []const Event = &.{},
    last_filters: []const Filter = &.{},

    const vtable: Store.VTable = .{ .put = put, .query = query };

    fn store(self: *StubStore) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn put(ptr: *anyopaque, event: *const Event) Error!PutResult {
        const self: *StubStore = @ptrCast(@alignCast(ptr));
        self.last_put = event;
        return self.put_result;
    }

    fn query(ptr: *anyopaque, filters: []const Filter, sink: Sink) QueryError!void {
        const self: *StubStore = @ptrCast(@alignCast(ptr));
        self.last_filters = filters;
        for (self.events) |*event| try sink.emit(event);
    }
};

const Collector = struct {
    ids: [8][32]u8 = undefined,
    len: usize = 0,
    stop_after: usize = 8,

    fn sink(self: *Collector) Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) Sink.Abort!void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        if (self.len == self.stop_after) return error.Abort;
        self.ids[self.len] = event.id;
        self.len += 1;
    }
};

fn testEvent(id_byte: u8) Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0} ** 32,
        .created_at = 1700000000,
        .kind = 1,
        .tags = &.{},
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

test "put carries the event and the result across the vtable" {
    var stub: StubStore = .{ .put_result = .duplicate };
    const store = stub.store();

    const event = testEvent(0xaa);
    try testing.expectEqual(PutResult.duplicate, try store.put(&event));
    try testing.expectEqual(@as(?*const Event, &event), stub.last_put);
}

test "query carries the filters across the vtable" {
    const events = [_]Event{ testEvent(1), testEvent(2) };
    var stub: StubStore = .{ .events = &events };
    const store = stub.store();

    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 500 }, .{ .kinds = &.{7} } };
    var collector: Collector = .{};
    try store.query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 2), stub.last_filters.len);
    try testing.expectEqual(@as(?u32, 500), stub.last_filters[0].limit);
    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqualSlices(u8, &events[0].id, &collector.ids[0]);
}

test "a sink stops a query by returning Abort" {
    const events = [_]Event{ testEvent(1), testEvent(2), testEvent(3) };
    var stub: StubStore = .{ .events = &events };
    const store = stub.store();

    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(error.Abort, store.query(&.{}, collector.sink()));
    try testing.expectEqual(@as(usize, 1), collector.len);
}
