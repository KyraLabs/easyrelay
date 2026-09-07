//! The LMDB backend: easyrelay's own schema, not a third party's.
//!
//! The data model this implements is docs/storage.md, and the reasoning behind
//! writing it here rather than taking one is
//! docs/adr/0010-first-party-lmdb-store.md. Nothing from `lmdb` appears above
//! this file (docs/adr/0008-store-abstraction-boundary.md).
//!
//! This file currently owns the environment, the `events` table, the `by_id`
//! and `by_created_at` indexes, and the `Store` implementation over them. The
//! remaining indexes, kind semantics and the query planner arrive with the
//! commits that need them.

const std = @import("std");
const lmdb = @import("lmdb");
const nostr = @import("nostr");

const record = @import("record.zig");
const store = @import("store.zig");

const Event = nostr.event.Event;
const Filter = nostr.filter.Filter;
const PutResult = store.PutResult;
const Sink = store.Sink;
const Store = store.Store;
const StoreError = store.Error;
const StoreQueryError = store.QueryError;

pub const Error = error{
    OutOfMemory,
    /// The data directory could not be created.
    DataDirectory,
    /// LMDB refused the operation. The commonest cause at open by far is a
    /// `map_size` the address space cannot satisfy.
    Backend,
    /// A stored record could not be read back. It means corruption, because
    /// every record in the store was written by `encode`.
    Corrupt,
};

pub const Options = struct {
    /// Address space, not a disk reservation, but a ceiling fixed until the
    /// next restart. The default matches `storage.map_size` in
    /// docs/configuration.md.
    map_size: usize = 10 * 1024 * 1024 * 1024,
    /// LMDB's own default. Phase 3 bounds the I/O pool below it and makes it
    /// configurable; until then, raising it would be a number with no reader.
    max_readers: u32 = 126,
};

/// The environment sits in a subdirectory rather than directly in the data
/// directory, which keeps the latter free for the search index and whatever
/// else grows beside it.
pub const subdirectory = "events";

/// Fixed when the environment opens and raisable only by reopening, so it
/// covers docs/storage.md's index table with room for what Phase 4 adds rather
/// than the two databases that exist today.
const max_databases = 16;

const events_db = "events";
const meta_db = "meta";
const by_id_db = "by_id";
const by_created_at_db = "by_created_at";
const next_local_id_key = "next_local_id";

/// Local ids start at 1 so that zero is available as "before every event",
/// which is what a subscription's watermark holds until its stored phase has
/// seen anything.
pub const first_local_id: u64 = 1;

pub fn encodeLocalId(local_id: u64) [8]u8 {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, local_id, .big);
    return key;
}

/// `created_at` encoded so that ascending byte order is *descending* time: the
/// sign bit is flipped to make the two's-complement range sort correctly, then
/// the whole thing is inverted.
///
/// The inversion is what lets one forward cursor walk produce the order
/// docs/protocol.md requires — newest `created_at` first, ties by ascending
/// event id — with the event id appended unchanged and nothing buffered. A key
/// of ascending time walked backwards cannot do it, because the tie-break would
/// come out descending too.
fn descendingTime(created_at: i64) [8]u8 {
    const biased: u64 = @as(u64, @bitCast(created_at)) ^ (@as(u64, 1) << 63);
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, ~biased, .big);
    return key;
}

const CreatedAtKey = [40]u8;

fn createdAtKey(created_at: i64, id: *const [32]u8) CreatedAtKey {
    var key: CreatedAtKey = undefined;
    key[0..8].* = descendingTime(created_at);
    key[8..40].* = id.*;
    return key;
}

pub const Lmdb = struct {
    gpa: std.mem.Allocator,
    env: lmdb.Environment,
    /// Read from `meta` at open and advanced by `append`. Only the writer
    /// thread touches it (docs/adr/0005-concurrency-model.md), so it needs no
    /// lock.
    next_local_id: u64,

    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        data_dir: []const u8,
        options: Options,
    ) Error!Lmdb {
        const path = try std.fs.path.joinZ(gpa, &.{ data_dir, subdirectory });
        defer gpa.free(path);

        std.Io.Dir.cwd().createDirPath(io, path) catch return error.DataDirectory;

        const env = lmdb.Environment.init(path, .{
            .map_size = options.map_size,
            .max_readers = options.max_readers,
            .max_dbs = max_databases,
        }) catch return error.Backend;
        errdefer env.deinit();

        const next_local_id = readNextLocalId(env) catch return error.Backend;
        return .{ .gpa = gpa, .env = env, .next_local_id = next_local_id };
    }

    /// The `Store` interface over this backend, and the only way above
    /// `src/storage/` to reach its events
    /// (docs/adr/0008-store-abstraction-boundary.md).
    pub fn store(self: *Lmdb) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *Lmdb) void {
        self.env.deinit();
        self.* = undefined;
    }

    /// Stores `event` at a freshly allocated local id, encoding it through
    /// `buffer`, and returns that id. The transaction is the caller's so that
    /// a whole batch commits once (docs/roadmap.md).
    pub fn append(
        self: *Lmdb,
        txn: lmdb.Transaction,
        buffer: []u8,
        event: *const Event,
    ) Error!u64 {
        const size = record.encode(buffer, event) catch return error.Backend;

        const local_id = self.next_local_id;
        const key = encodeLocalId(local_id);

        const events = lmdb.Database.open(txn, events_db, .{ .create = true }) catch
            return error.Backend;
        events.set(&key, buffer[0..size]) catch return error.Backend;

        const by_id = lmdb.Database.open(txn, by_id_db, .{ .create = true }) catch
            return error.Backend;
        by_id.set(&event.id, &key) catch return error.Backend;

        const by_created_at = lmdb.Database.open(txn, by_created_at_db, .{ .create = true }) catch
            return error.Backend;
        const index_key = createdAtKey(event.created_at, &event.id);
        by_created_at.set(&index_key, &key) catch return error.Backend;

        const meta = lmdb.Database.open(txn, meta_db, .{ .create = true }) catch
            return error.Backend;
        const next = encodeLocalId(local_id + 1);
        meta.set(next_local_id_key, &next) catch return error.Backend;

        self.next_local_id = local_id + 1;
        return local_id;
    }

    /// Whether `id` is already stored, which is what tells `put` a `duplicate:`
    /// from a `stored`.
    pub fn contains(self: *Lmdb, txn: lmdb.Transaction, id: *const [32]u8) Error!bool {
        _ = self;
        const by_id = lmdb.Database.open(txn, by_id_db, .{ .create = true }) catch
            return error.Backend;
        const found = by_id.get(id) catch return error.Backend;
        return found != null;
    }

    /// Reads the event at `local_id`. Everything but the tag structure aliases
    /// the memory map, so the result is valid only while `txn` is open.
    pub fn read(
        self: *Lmdb,
        txn: lmdb.Transaction,
        allocator: std.mem.Allocator,
        local_id: u64,
    ) Error!?Event {
        _ = self;
        const events = lmdb.Database.open(txn, events_db, .{}) catch return error.Backend;
        const key = encodeLocalId(local_id);
        const bytes = (events.get(&key) catch return error.Backend) orelse return null;
        return record.decode(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Malformed => error.Corrupt,
        };
    }

    const vtable: Store.VTable = .{ .put = putErased, .query = queryErased };

    fn putErased(ptr: *anyopaque, event: *const Event) StoreError!PutResult {
        const self: *Lmdb = @ptrCast(@alignCast(ptr));
        return self.put(event) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Backend,
        };
    }

    fn queryErased(
        ptr: *anyopaque,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) StoreQueryError!void {
        const self: *Lmdb = @ptrCast(@alignCast(ptr));
        return self.query(filters, limit, sink) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Abort => error.Abort,
            else => error.Backend,
        };
    }

    fn put(self: *Lmdb, event: *const Event) Error!PutResult {
        const size = record.encodedSize(event) catch return error.Backend;
        const buffer = try self.gpa.alloc(u8, size);
        defer self.gpa.free(buffer);

        const txn = lmdb.Transaction.init(self.env, .{ .mode = .ReadWrite }) catch
            return error.Backend;
        errdefer txn.abort();

        if (try self.contains(txn, &event.id)) {
            txn.abort();
            return .duplicate;
        }

        _ = try self.append(txn, buffer, event);
        txn.commit() catch return error.Backend;
        return .stored;
    }

    /// Walks `by_created_at` forwards, which is newest first, decoding each
    /// candidate and post-filtering it. One walk over a unique index is what
    /// makes the union free of duplicates and the `limit` global.
    ///
    /// The scan is bounded by `limit` matches but not yet by candidates
    /// examined: a selective filter still reads everything newer than its
    /// matches. `storage.max_scan` and the index selection that would avoid it
    /// arrive with the query planner.
    fn query(
        self: *Lmdb,
        filters: []const Filter,
        limit: usize,
        sink: Sink,
    ) (Error || Sink.Abort)!void {
        if (limit == 0 or filters.len == 0) return;

        const txn = lmdb.Transaction.init(self.env, .{ .mode = .ReadOnly }) catch
            return error.Backend;
        defer txn.abort();

        const by_created_at = lmdb.Database.open(txn, by_created_at_db, .{ .create = true }) catch
            return error.Backend;
        const cursor = lmdb.Cursor.init(by_created_at) catch return error.Backend;
        defer cursor.deinit();

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        var emitted: usize = 0;
        var key = cursor.goToFirst() catch return error.Backend;
        while (key != null) : (key = cursor.goToNext() catch return error.Backend) {
            const value = cursor.getCurrentValue() catch return error.Backend;
            if (value.len != 8) return error.Corrupt;

            _ = arena.reset(.retain_capacity);
            const local_id = std.mem.readInt(u64, value[0..8], .big);
            const event = (try self.read(txn, arena.allocator(), local_id)) orelse
                return error.Corrupt;

            if (!matchesAny(filters, &event)) continue;
            try sink.emit(&event);
            emitted += 1;
            if (emitted == limit) break;
        }
        std.debug.assert(emitted <= limit);
    }
};

fn matchesAny(filters: []const Filter, event: *const Event) bool {
    for (filters) |filter| {
        if (filter.matches(event.*)) return true;
    }
    return false;
}

fn readNextLocalId(env: lmdb.Environment) !u64 {
    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    const meta = try lmdb.Database.open(txn, meta_db, .{ .create = true });
    _ = try lmdb.Database.open(txn, events_db, .{ .create = true });

    const stored = try meta.get(next_local_id_key);
    const next = if (stored) |bytes| blk: {
        if (bytes.len != 8) return error.Corrupt;
        break :blk std.mem.readInt(u64, bytes[0..8], .big);
    } else first_local_id;

    try txn.commit();
    return next;
}

const testing = std.testing;

fn tmpPath(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..len];
}

test "open creates the data directory when it does not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &buffer);

    const data_dir = try std.fs.path.join(testing.allocator, &.{ root, "missing" });
    defer testing.allocator.free(data_dir);

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    backend.close();

    var opened = try std.Io.Dir.cwd().openDir(testing.io, data_dir, .{});
    opened.close(testing.io);
}

test "open twice over the same directory reaches the same environment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &buffer);

    {
        var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer backend.close();

        const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadWrite });
        errdefer txn.abort();
        try txn.set("k", "v");
        try txn.commit();
    }

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadOnly });
    defer txn.abort();
    try testing.expectEqualStrings("v", (try txn.get("k")).?);
}

test "a map size the address space cannot satisfy fails to open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &buffer);

    try testing.expectError(
        error.Backend,
        Lmdb.open(testing.allocator, testing.io, data_dir, .{ .map_size = std.math.maxInt(usize) }),
    );
}

fn testEvent(id_byte: u8, created_at: i64) Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0xbb} ** 32,
        .sig = [_]u8{0xcc} ** 64,
        .created_at = created_at,
        .kind = 1,
        .tags = &.{},
        .content = "",
    };
}

fn appendOne(backend: *Lmdb, buffer: []u8, event: *const Event) !u64 {
    const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadWrite });
    errdefer txn.abort();
    const local_id = try backend.append(txn, buffer, event);
    try txn.commit();
    return local_id;
}

test "local ids start at one and increase with insertion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    var buffer: [4096]u8 = undefined;
    const first = testEvent(1, 1700000000);
    const second = testEvent(2, 1700000100);

    try testing.expectEqual(first_local_id, try appendOne(&backend, &buffer, &first));
    try testing.expectEqual(first_local_id + 1, try appendOne(&backend, &buffer, &second));
}

test "an appended event reads back through its local id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    const tags = [_]nostr.event.Tag{&.{ "d", "value" }};
    var event = testEvent(7, 1700000000);
    event.tags = &tags;
    event.content = "stored";

    var buffer: [4096]u8 = undefined;
    const local_id = try appendOne(&backend, &buffer, &event);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const read_back = (try backend.read(txn, arena.allocator(), local_id)).?;
    try testing.expectEqualSlices(u8, &event.id, &read_back.id);
    try testing.expectEqualStrings("stored", read_back.content);
    try testing.expectEqualStrings("value", read_back.tags[0][1]);
}

test "reading a local id that was never assigned gives null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadOnly });
    defer txn.abort();

    try testing.expectEqual(@as(?Event, null), try backend.read(txn, arena.allocator(), 99));
}

test "the local id counter survives a reopen and does not restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var buffer: [4096]u8 = undefined;
    var last: u64 = undefined;
    {
        var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer backend.close();
        const event = testEvent(1, 1700000000);
        _ = try appendOne(&backend, &buffer, &event);
        last = try appendOne(&backend, &buffer, &testEvent(2, 1700000100));
    }

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    const event = testEvent(3, 1700000200);
    try testing.expectEqual(last + 1, try appendOne(&backend, &buffer, &event));
}

test "an aborted transaction assigns no id that a later append reuses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var buffer: [4096]u8 = undefined;
    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    const event = testEvent(1, 1700000000);
    {
        const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadWrite });
        _ = try backend.append(txn, &buffer, &event);
        txn.abort();
    }

    // The in-memory counter advanced with the append that was rolled back, so
    // the id it handed out is skipped rather than handed out twice. Skipping is
    // free; reuse would make the watermark in docs/roadmap.md wrong.
    var backend_after = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend_after.close();

    try testing.expectEqual(first_local_id, try appendOne(&backend_after, &buffer, &event));
}

/// Collects what a query emitted, in order. Its slices borrow the store, which
/// outlives every assertion made against them here.
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

const Fixture = struct {
    tmp: testing.TmpDir,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    backend: Lmdb = undefined,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        const data_dir = try tmpPath(&self.tmp, &self.buffer);
        self.backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    }

    fn deinit(self: *Fixture) void {
        self.backend.close();
        self.tmp.cleanup();
    }
};

fn kindEvent(id_byte: u8, created_at: i64, kind: u16) Event {
    var event = testEvent(id_byte, created_at);
    event.kind = kind;
    event.pubkey = [_]u8{0xab} ** 32;
    return event;
}

test "put stores an event and reports a repeat as a duplicate" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const event = kindEvent(1, 1700000000, 1);
    try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(&event));
    try testing.expectEqual(PutResult.duplicate, try fixture.backend.store().put(&event));
}

test "query streams newest first" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(3, 1700000200, 1),
        kindEvent(2, 1700000100, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
    try testing.expectEqual(@as(u8, 1), collector.idAt(2));
}

test "events sharing a created_at are ordered by ascending id" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // Inserted in an order that is neither the answer nor its reverse, so that
    // neither insertion order nor local id can be mistaken for the tie-break
    // docs/protocol.md requires.
    for ([_]Event{
        kindEvent(0xcc, 1700000000, 1),
        kindEvent(0xaa, 1700000000, 1),
        kindEvent(0xbb, 1700000000, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(u8, 0xaa), collector.idAt(0));
    try testing.expectEqual(@as(u8, 0xbb), collector.idAt(1));
    try testing.expectEqual(@as(u8, 0xcc), collector.idAt(2));
}

test "a negative created_at sorts older than the epoch rather than newer" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, -100, 1),
        kindEvent(2, 0, 1),
        kindEvent(3, 100, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
    try testing.expectEqual(@as(u8, 1), collector.idAt(2));
}

test "filters are OR-ed and an event matching several is emitted once" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(2, 1700000100, 7),
        kindEvent(3, 1700000200, 30023),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{
        .{ .kinds = &.{1} },
        .{ .kinds = &.{7} },
        .{ .authors = &.{[_]u8{0xab} ** 32} },
    };
    try fixture.backend.store().query(&filters, 10, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
}

test "limit bounds the stored phase across the whole merge" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(2, 1700000100, 7),
        kindEvent(3, 1700000200, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1} }, .{ .kinds = &.{7} } };
    try fixture.backend.store().query(&filters, 2, collector.sink());

    try testing.expectEqual(@as(usize, 2), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
}

test "no filters and a zero limit both emit nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const event = kindEvent(1, 1700000000, 1);
    _ = try fixture.backend.store().put(&event);

    var no_filters: Collector = .{};
    try fixture.backend.store().query(&.{}, 10, no_filters.sink());
    try testing.expectEqual(@as(usize, 0), no_filters.len);

    var zero_limit: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, 0, zero_limit.sink());
    try testing.expectEqual(@as(usize, 0), zero_limit.len);
}

test "a sink that aborts stops the query" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(2, 1700000100, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(
        error.Abort,
        fixture.backend.store().query(&.{.{}}, 10, collector.sink()),
    );
    try testing.expectEqual(@as(usize, 1), collector.len);
}

test "events published before a restart are queryable after it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    {
        var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer backend.close();

        var event = kindEvent(9, 1700000000, 1);
        event.content = "survives";
        _ = try backend.store().put(&event);
    }

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    var collector: Collector = .{};
    try backend.store().query(&.{.{}}, 10, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 9), collector.idAt(0));
    try testing.expectEqualStrings("survives", collector.contents[0]);
}
