//! The `Store` interface: the only way anything above `src/storage/` reaches
//! stored events.
//!
//! The boundary is load-bearing rather than decorative — see
//! docs/adr/0008-store-abstraction-boundary.md. Two of its rules are worth
//! restating where they are enforced:
//!
//! - No type from `zig-nostr`'s store appears here or in any layer above.
//!   Its protocol primitives are shared vocabulary and do: an `Event` is a
//!   NIP-01 event whoever produced it.
//! - The interface is shaped by what the relay needs, from docs/protocol.md,
//!   not by what a backend finds convenient to expose. Where the two differ,
//!   the backend absorbs the difference.
//!
//! Phase 1 needs `put` and `query`. Batched writes, deletion (NIP-09),
//! expiration (NIP-40) and counting (NIP-45) arrive with the phase that uses
//! them; a vtable grows without disturbing its callers, and a signature with
//! no caller is a guess.

const std = @import("std");
const nostr = @import("nostr");

const Event = nostr.event.Event;
const Filter = nostr.filter.Filter;

/// What a backend may fail with. Explicit at the boundary because it is the
/// contract: a new failure mode inside a backend cannot leak silently through
/// the call graph, it has to be mapped onto one of these or added here.
pub const Error = error{
    OutOfMemory,
    /// The storage engine failed. The backend has the detail and logs it; the
    /// relay's only recourse is `error:` to the client, so it needs no more
    /// than the fact. Zig errors carry no payload, and a variant per LMDB
    /// status code would be a vocabulary nothing above here can act on.
    Backend,
};

/// Errors a `query` may end with: the backend's own, plus the sink's request
/// to stop.
pub const QueryError = Error || Sink.Abort;

/// What became of an event handed to `put`.
///
/// Phase 2 adds the outcomes that kind semantics produce — superseded a
/// replaceable incumbent, lost the tie-break, refused because its author
/// deleted it. Until those exist, inventing names for them would be fiction.
pub const PutResult = enum {
    /// The store did not hold this id and now does.
    stored,
    /// The store already held this id; nothing changed. The relay answers
    /// `OK true` with a `duplicate:` message — the client's event is on the
    /// relay, which is what it asked for (docs/protocol.md).
    duplicate,
};

/// Where `query` sends matching events, one at a time.
///
/// The event handed to `emit` borrows the store's memory and is valid only
/// until `emit` returns. An LMDB-backed store hands out a view held open by a
/// read transaction that ends with the query; a sink that keeps an event
/// copies it first.
///
/// Streaming rather than returning a slice is what keeps a large `REQ` from
/// costing memory in proportion to its result set, and what lets a slow
/// subscriber be disconnected without the relay having already built the
/// answer (docs/storage.md).
pub const Sink = struct {
    ptr: *anyopaque,
    emitFn: *const fn (ptr: *anyopaque, event: *const Event) Abort!void,

    /// How a sink stops a query early: the client disconnected, its write
    /// buffer filled, the subscription was closed underneath it. The reason
    /// belongs to the sink, which already knows it and can report it; the
    /// store only needs to know to stop and unwind.
    pub const Abort = error{Abort};

    pub fn emit(self: Sink, event: *const Event) Abort!void {
        return self.emitFn(self.ptr, event);
    }
};

/// A storage backend, resolved at runtime so that the relay, its tests and its
/// property tests can run against different ones. The shape is
/// `std.mem.Allocator`'s: a type-erased pointer and a table of functions.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, event: *const Event) Error!PutResult,
        query: *const fn (
            ptr: *anyopaque,
            filters: []const Filter,
            limit: usize,
            sink: Sink,
        ) QueryError!void,
    };

    /// Stores `event` and reports what became of it.
    ///
    /// The store copies whatever it retains. Nothing borrowed from `event`
    /// survives the call: the caller's per-request arena is reset as soon as
    /// the message is answered.
    pub fn put(self: Store, event: *const Event) Error!PutResult {
        return self.vtable.put(self.ptr, event);
    }

    /// Streams every stored event matching *any* of `filters` to `sink`.
    ///
    /// The contract is docs/protocol.md's, it is identical for every backend,
    /// and it is what the property test in docs/testing.md holds them to:
    ///
    /// - **Union.** Filters are OR-ed with each other, and the fields within
    ///   one filter are AND-ed. An event matching several filters is emitted
    ///   once.
    /// - **Order.** Newest first by `created_at`, ties broken by ascending id.
    /// - **Bound.** At most `limit` events, applied across the merged result
    ///   and selecting the globally newest. `Filter.limit` is ignored, because
    ///   it cannot express a bound that spans filters: applying it per filter
    ///   and concatenating returns plausible and wrong events. The caller
    ///   resolves the effective limit from the subscription and from the
    ///   configured `default_limit` and `max_limit`.
    /// - **No materialisation.** Events reach `sink` as they are found, not
    ///   after the answer is complete.
    ///
    /// A `limit` of zero emits nothing, which is what an empty filter array
    /// and a zero limit both mean: no stored events, then `EOSE`.
    pub fn query(
        self: Store,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) QueryError!void {
        return self.vtable.query(self.ptr, filters, limit, sink);
    }
};

const testing = std.testing;

/// Records what it was handed and replays what it was told to. What is under
/// test here is the wiring — that arguments and results cross the vtable
/// untouched — not storage, which `memory.zig` covers.
const StubStore = struct {
    put_result: PutResult = .stored,
    last_put: ?*const Event = null,
    events: []const Event = &.{},
    last_filters: []const Filter = &.{},
    last_limit: usize = 0,

    const vtable: Store.VTable = .{ .put = put, .query = query };

    fn store(self: *StubStore) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn put(ptr: *anyopaque, event: *const Event) Error!PutResult {
        const self: *StubStore = @ptrCast(@alignCast(ptr));
        self.last_put = event;
        return self.put_result;
    }

    fn query(
        ptr: *anyopaque,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) QueryError!void {
        const self: *StubStore = @ptrCast(@alignCast(ptr));
        self.last_filters = filters;
        self.last_limit = limit;
        for (self.events) |*event| try sink.emit(event);
    }
};

/// Collects into a fixed buffer and can be told to give up part way, which is
/// what a disconnected client looks like from the store's side.
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

test "query carries the filters and the limit across the vtable" {
    const events = [_]Event{ testEvent(1), testEvent(2) };
    var stub: StubStore = .{ .events = &events };
    const store = stub.store();

    const filters = [_]Filter{ .{ .kinds = &.{1} }, .{ .kinds = &.{7} } };
    var collector: Collector = .{};
    try store.query(&filters, 500, collector.sink());

    try testing.expectEqual(@as(usize, 2), stub.last_filters.len);
    try testing.expectEqual(@as(usize, 500), stub.last_limit);
    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqualSlices(u8, &events[0].id, &collector.ids[0]);
}

test "a sink stops a query by returning Abort" {
    const events = [_]Event{ testEvent(1), testEvent(2), testEvent(3) };
    var stub: StubStore = .{ .events = &events };
    const store = stub.store();

    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(error.Abort, store.query(&.{}, 500, collector.sink()));
    try testing.expectEqual(@as(usize, 1), collector.len);
}
