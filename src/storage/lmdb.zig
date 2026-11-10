const std = @import("std");
const lmdb = @import("lmdb");
const nostr = @import("nostr");

const kinds = @import("kind.zig");
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
    DataDirectory,
    Backend,
    Corrupt,
};

pub const Options = struct {
    map_size: usize = 10 * 1024 * 1024 * 1024,
    max_readers: u32 = 126,
};

pub const subdirectory = "events";

const max_databases = 16;

const events_db = "events";
const meta_db = "meta";
const by_id_db = "by_id";
const by_created_at_db = "by_created_at";
const by_replaceable_db = "by_replaceable";
const by_address_db = "by_address";
const next_local_id_key = "next_local_id";

/// Zero is reserved as the watermark before any event.
pub const first_local_id: u64 = 1;

pub fn encodeLocalId(local_id: u64) [8]u8 {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, local_id, .big);
    return key;
}

/// Sign-flipped and inverted so a forward walk yields newest first, ties by ascending id.
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

/// The `d` value is hashed because LMDB keys are capped at 511 bytes.
const Coordinate = struct {
    db: [*:0]const u8,
    bytes: [66]u8,
    len: usize,

    fn of(event: *const Event) ?Coordinate {
        var coordinate: Coordinate = .{ .db = undefined, .bytes = undefined, .len = 34 };
        coordinate.bytes[0..32].* = event.pubkey;
        std.mem.writeInt(u16, coordinate.bytes[32..34], event.kind, .big);
        switch (kinds.classify(event.kind)) {
            .replaceable => coordinate.db = by_replaceable_db,
            .addressable => {
                coordinate.db = by_address_db;
                std.crypto.hash.sha2.Sha256.hash(kinds.dValue(event), coordinate.bytes[34..66], .{});
                coordinate.len = 66;
            },
            .regular, .ephemeral => return null,
        }
        return coordinate;
    }

    fn key(self: *const Coordinate) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn database(txn: lmdb.Transaction, name: [*:0]const u8) Error!lmdb.Database {
    return lmdb.Database.open(txn, name, .{ .create = true }) catch error.Backend;
}

fn writeIndexes(txn: lmdb.Transaction, event: *const Event, local_key: *const [8]u8) Error!void {
    (try database(txn, by_id_db)).set(&event.id, local_key) catch return error.Backend;
    const created_at_key = createdAtKey(event.created_at, &event.id);
    (try database(txn, by_created_at_db)).set(&created_at_key, local_key) catch return error.Backend;
    if (Coordinate.of(event)) |coordinate| {
        (try database(txn, coordinate.db)).set(coordinate.key(), local_key) catch return error.Backend;
    }
}

fn deleteIndexes(txn: lmdb.Transaction, event: *const Event) Error!void {
    (try database(txn, by_id_db)).delete(&event.id) catch return error.Backend;
    const created_at_key = createdAtKey(event.created_at, &event.id);
    (try database(txn, by_created_at_db)).delete(&created_at_key) catch return error.Backend;
    if (Coordinate.of(event)) |coordinate| {
        (try database(txn, coordinate.db)).delete(coordinate.key()) catch return error.Backend;
    }
}

pub const Lmdb = struct {
    gpa: std.mem.Allocator,
    env: lmdb.Environment,
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

    pub fn store(self: *Lmdb) Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *Lmdb) void {
        self.env.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *Lmdb,
        txn: lmdb.Transaction,
        buffer: []u8,
        event: *const Event,
    ) Error!u64 {
        const size = record.encode(buffer, event) catch return error.Backend;

        const local_id = self.next_local_id;
        const key = encodeLocalId(local_id);

        (try database(txn, events_db)).set(&key, buffer[0..size]) catch return error.Backend;
        try writeIndexes(txn, event, &key);

        const meta = lmdb.Database.open(txn, meta_db, .{ .create = true }) catch
            return error.Backend;
        const next = encodeLocalId(local_id + 1);
        meta.set(next_local_id_key, &next) catch return error.Backend;

        self.next_local_id = local_id + 1;
        return local_id;
    }

    pub fn contains(self: *Lmdb, txn: lmdb.Transaction, id: *const [32]u8) Error!bool {
        _ = self;
        const by_id = lmdb.Database.open(txn, by_id_db, .{ .create = true }) catch
            return error.Backend;
        const found = by_id.get(id) catch return error.Backend;
        return found != null;
    }

    /// The result aliases the memory map and is valid only while `txn` is open.
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

    fn queryErased(ptr: *anyopaque, filters: []const Filter, sink: Sink) StoreQueryError!void {
        const self: *Lmdb = @ptrCast(@alignCast(ptr));
        return self.query(filters, sink) catch |err| switch (err) {
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

        std.debug.assert(kinds.classify(event.kind) != .ephemeral);
        if (try self.contains(txn, &event.id)) {
            txn.abort();
            return .duplicate;
        }

        if (Coordinate.of(event)) |coordinate| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const found = (try database(txn, coordinate.db)).get(coordinate.key()) catch return error.Backend;
            if (found) |value| {
                if (value.len != 8) return error.Corrupt;
                const incumbent_id = std.mem.readInt(u64, value[0..8], .big);
                const incumbent = (try self.read(txn, arena.allocator(), incumbent_id)) orelse return error.Corrupt;
                if (!kinds.supersedes(event, &incumbent)) {
                    txn.abort();
                    return .outdated;
                }
                try deleteIndexes(txn, &incumbent);
                const incumbent_key = encodeLocalId(incumbent_id);
                (try database(txn, events_db)).delete(&incumbent_key) catch return error.Backend;
            }
        }

        _ = try self.append(txn, buffer, event);
        txn.commit() catch return error.Backend;
        return .stored;
    }

    fn query(self: *Lmdb, filters: []const Filter, sink: Sink) (Error || Sink.Abort)!void {
        const remaining = try self.gpa.alloc(u64, filters.len);
        defer self.gpa.free(remaining);
        var pending: usize = 0;
        for (filters, remaining) |filter, *left| {
            left.* = filter.limit orelse std.math.maxInt(u64);
            if (left.* != 0) pending += 1;
        }
        if (pending == 0) return;

        const txn = lmdb.Transaction.init(self.env, .{ .mode = .ReadOnly }) catch
            return error.Backend;
        defer txn.abort();

        const by_created_at = lmdb.Database.open(txn, by_created_at_db, .{ .create = true }) catch
            return error.Backend;
        const cursor = lmdb.Cursor.init(by_created_at) catch return error.Backend;
        defer cursor.deinit();

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        var key = cursor.goToFirst() catch return error.Backend;
        while (key != null and pending != 0) : (key = cursor.goToNext() catch return error.Backend) {
            const value = cursor.getCurrentValue() catch return error.Backend;
            if (value.len != 8) return error.Corrupt;

            _ = arena.reset(.retain_capacity);
            const local_id = std.mem.readInt(u64, value[0..8], .big);
            const event = (try self.read(txn, arena.allocator(), local_id)) orelse
                return error.Corrupt;

            var wanted = false;
            for (filters, remaining) |filter, *left| {
                if (left.* == 0 or !filter.matches(event)) continue;
                left.* -= 1;
                if (left.* == 0) pending -= 1;
                wanted = true;
            }
            if (wanted) try sink.emit(&event);
        }
    }
};

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

    var backend_after = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend_after.close();

    try testing.expectEqual(first_local_id, try appendOne(&backend_after, &buffer, &event));
}

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
    try fixture.backend.store().query(&.{.{}}, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
    try testing.expectEqual(@as(u8, 2), collector.idAt(1));
    try testing.expectEqual(@as(u8, 1), collector.idAt(2));
}

test "events sharing a created_at are ordered by ascending id" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(0xcc, 1700000000, 1),
        kindEvent(0xaa, 1700000000, 1),
        kindEvent(0xbb, 1700000000, 1),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, collector.sink());

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
    try fixture.backend.store().query(&.{.{}}, collector.sink());

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
    try fixture.backend.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 3), collector.idAt(0));
}

test "each filter's limit bounds only that filter's matches" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(2, 1700000100, 7),
        kindEvent(3, 1700000200, 1),
        kindEvent(4, 1700000300, 7),
    }) |event| _ = try fixture.backend.store().put(&event);

    var collector: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 1 }, .{ .kinds = &.{7}, .limit = 2 } };
    try fixture.backend.store().query(&filters, collector.sink());

    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 4), collector.idAt(0));
    try testing.expectEqual(@as(u8, 3), collector.idAt(1));
    try testing.expectEqual(@as(u8, 2), collector.idAt(2));
}

test "no filters and a zero limit both emit nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    for ([_]Event{
        kindEvent(1, 1700000000, 1),
        kindEvent(2, 1700000100, 7),
    }) |event| _ = try fixture.backend.store().put(&event);

    var no_filters: Collector = .{};
    try fixture.backend.store().query(&.{}, no_filters.sink());
    try testing.expectEqual(@as(usize, 0), no_filters.len);

    var zero_limit: Collector = .{};
    const filters = [_]Filter{ .{ .kinds = &.{1}, .limit = 0 }, .{ .kinds = &.{7}, .limit = 1 } };
    try fixture.backend.store().query(&filters, zero_limit.sink());
    try testing.expectEqual(@as(usize, 1), zero_limit.len);
    try testing.expectEqual(@as(u8, 2), zero_limit.idAt(0));
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
        fixture.backend.store().query(&.{.{}}, collector.sink()),
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
    try backend.store().query(&.{.{}}, collector.sink());

    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 9), collector.idAt(0));
    try testing.expectEqualStrings("survives", collector.contents[0]);
}

fn entryCount(backend: *Lmdb, name: [*:0]const u8) !usize {
    const txn = try lmdb.Transaction.init(backend.env, .{ .mode = .ReadWrite });
    defer txn.abort();
    const db = try database(txn, name);
    return (try db.stat()).entries;
}

test "a superseded replaceable event is removed from every table" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const old = kindEvent(1, 1700000000, 0);
    const new = kindEvent(2, 1700000100, 0);
    try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(&old));
    try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(&new));
    try testing.expectEqual(PutResult.outdated, try fixture.backend.store().put(&old));

    for ([_][*:0]const u8{ events_db, by_id_db, by_created_at_db, by_replaceable_db }) |name| {
        try testing.expectEqual(@as(usize, 1), try entryCount(&fixture.backend, name));
    }

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 2), collector.idAt(0));
}

test "a replaceable tie on created_at keeps the lexically smaller id" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const larger = kindEvent(0xbb, 1700000000, 3);
    const smaller = kindEvent(0xaa, 1700000000, 3);
    try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(&larger));
    try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(&smaller));
    try testing.expectEqual(PutResult.outdated, try fixture.backend.store().put(&larger));

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expectEqual(@as(u8, 0xaa), collector.idAt(0));
}

test "addressable events replace only within their d coordinate, and a long d value fits" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const long_d = "d" ** 600;
    var a1 = kindEvent(1, 1700000000, 30023);
    a1.tags = &.{&.{ "d", long_d }};
    var b1 = kindEvent(2, 1700000000, 30023);
    b1.tags = &.{&.{ "d", "b" }};
    var a2 = kindEvent(3, 1700000100, 30023);
    a2.tags = &.{&.{ "d", long_d }};
    var bare = kindEvent(4, 1700000200, 30023);
    bare.tags = &.{&.{"d"}};
    var absent = kindEvent(5, 1700000300, 30023);
    absent.tags = &.{};

    for ([_]*const Event{ &a1, &b1, &a2, &bare, &absent }) |event| {
        try testing.expectEqual(PutResult.stored, try fixture.backend.store().put(event));
    }

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(usize, 3), collector.len);
    try testing.expectEqual(@as(u8, 5), collector.idAt(0));
    try testing.expectEqual(@as(u8, 3), collector.idAt(1));
    try testing.expectEqual(@as(u8, 2), collector.idAt(2));
    try testing.expectEqual(@as(usize, 3), try entryCount(&fixture.backend, by_address_db));
}

test "replacement holds across a restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    {
        var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer backend.close();
        const new = kindEvent(2, 1700000100, 10002);
        _ = try backend.store().put(&new);
    }

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();
    const old = kindEvent(1, 1700000000, 10002);
    try testing.expectEqual(PutResult.outdated, try backend.store().put(&old));
}
