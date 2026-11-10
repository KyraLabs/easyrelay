const std = @import("std");
const lmdb = @import("lmdb");
const nostr = @import("nostr");

const index = @import("index.zig");
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
    max_scan: usize = 100_000,
};

pub const subdirectory = "events";

const max_databases = 16;

const events_db = "events";
const meta_db = "meta";
const by_id_db = "by_id";
const by_replaceable_db = "by_replaceable";
const by_address_db = "by_address";
const deleted_db = "deleted";
const deleted_address_db = "deleted_address";
const next_local_id_key = "next_local_id";

/// Zero is reserved as the watermark before any event.
pub const first_local_id: u64 = 1;

pub fn encodeLocalId(local_id: u64) [8]u8 {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, local_id, .big);
    return key;
}

/// The `d` value is hashed because LMDB keys are capped at 511 bytes.
const Coordinate = struct {
    db: [*:0]const u8,
    bytes: [66]u8,
    len: usize,

    fn of(event: *const Event) ?Coordinate {
        return from(&event.pubkey, event.kind, kinds.dValue(event));
    }

    fn from(pubkey: *const [32]u8, kind: u16, d: []const u8) ?Coordinate {
        var coordinate: Coordinate = .{ .db = undefined, .bytes = undefined, .len = 34 };
        coordinate.bytes[0..32].* = pubkey.*;
        std.mem.writeInt(u16, coordinate.bytes[32..34], kind, .big);
        switch (kinds.classify(kind)) {
            .replaceable => coordinate.db = by_replaceable_db,
            .addressable => {
                coordinate.db = by_address_db;
                std.crypto.hash.sha2.Sha256.hash(d, coordinate.bytes[34..66], .{});
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

/// Read inside the transaction, so a second process writing the same environment cannot reuse an id.
fn nextLocalId(txn: lmdb.Transaction) Error!u64 {
    const meta = lmdb.Database.open(txn, meta_db, .{}) catch return error.Backend;
    const value = (meta.get(next_local_id_key) catch return error.Backend) orelse return first_local_id;
    if (value.len != 8) return error.Corrupt;
    const next = std.mem.readInt(u64, value[0..8], .big);
    if (next < first_local_id) return error.Corrupt;
    return next;
}

fn snapshotWatermark(txn: lmdb.Transaction) Error!u64 {
    return try nextLocalId(txn) - 1;
}

/// A failed commit has already freed the transaction, so it must not be aborted again.
fn commit(txn: lmdb.Transaction) Error!void {
    txn.commit() catch return error.Backend;
}

fn deletedUntil(txn: lmdb.Transaction, coordinate: *const Coordinate) Error!?i64 {
    const value = ((try database(txn, deleted_address_db)).get(coordinate.key()) catch return error.Backend) orelse return null;
    if (value.len != 8) return error.Corrupt;
    return std.mem.readInt(i64, value[0..8], .big);
}

fn remove(txn: lmdb.Transaction, target: *const Lmdb.Stored) Error!void {
    try deleteIndexes(txn, &target.event);
    const key = encodeLocalId(target.local_id);
    (try database(txn, events_db)).delete(&key) catch return error.Backend;
}

const IndexWriter = struct {
    txn: lmdb.Transaction,
    local_key: *const [8]u8,
    delete: bool,

    pub fn entry(self: IndexWriter, which: index.Index, key: index.Key) Error!void {
        const db = try database(self.txn, which.name());
        if (self.delete) {
            db.delete(key.slice()) catch return error.Backend;
        } else {
            db.set(key.slice(), self.local_key) catch return error.Backend;
        }
    }
};

fn writeIndexes(txn: lmdb.Transaction, event: *const Event, local_key: *const [8]u8) Error!void {
    (try database(txn, by_id_db)).set(&event.id, local_key) catch return error.Backend;
    try index.forEachEntry(event, IndexWriter{ .txn = txn, .local_key = local_key, .delete = false });
    if (Coordinate.of(event)) |coordinate| {
        (try database(txn, coordinate.db)).set(coordinate.key(), local_key) catch return error.Backend;
    }
}

fn deleteIndexes(txn: lmdb.Transaction, event: *const Event) Error!void {
    const unused = [_]u8{0} ** 8;
    (try database(txn, by_id_db)).delete(&event.id) catch return error.Backend;
    try index.forEachEntry(event, IndexWriter{ .txn = txn, .local_key = &unused, .delete = true });
    if (Coordinate.of(event)) |coordinate| {
        (try database(txn, coordinate.db)).delete(coordinate.key()) catch return error.Backend;
    }
}

const max_prefixes_per_filter = 64;

fn idLessThan(_: void, a: [32]u8, b: [32]u8) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

const Head = struct {
    tail: index.Suffix,
    local_id: u64,

    fn lessThan(_: void, a: Head, b: Head) bool {
        return std.mem.order(u8, &a.tail, &b.tail) == .lt;
    }
};

const Source = struct {
    filter: usize,
    head: ?Head = null,
    input: union(enum) {
        cursor: struct {
            cursor: lmdb.Cursor,
            prefix: index.Prefix,
            start: index.Key,
            oldest: [8]u8,
            started: bool = false,
        },
        list: struct { items: []const Head, next: usize = 0 },
    },

    fn advance(self: *Source) Error!void {
        switch (self.input) {
            .list => |*list| {
                self.head = if (list.next < list.items.len) list.items[list.next] else null;
                list.next += 1;
            },
            .cursor => |*walk| {
                const found = if (walk.started)
                    walk.cursor.goToNext() catch return error.Backend
                else
                    walk.cursor.seek(walk.start.slice()) catch return error.Backend;
                walk.started = true;
                self.head = null;
                const key = found orelse return;
                if (key.len != walk.prefix.len + index.suffix_len) return;
                if (!std.mem.startsWith(u8, key, walk.prefix.slice())) return;
                const tail = key[walk.prefix.len..][0..index.suffix_len];
                if (std.mem.order(u8, tail[0..8], &walk.oldest) == .gt) return;
                const value = walk.cursor.getCurrentValue() catch return error.Backend;
                if (value.len != 8) return error.Corrupt;
                self.head = .{ .tail = tail.*, .local_id = std.mem.readInt(u64, value[0..8], .big) };
            },
        }
    }

    fn deinit(self: *Source) void {
        switch (self.input) {
            .cursor => |walk| walk.cursor.deinit(),
            .list => {},
        }
    }
};

fn addCursor(
    txn: lmdb.Transaction,
    arena: std.mem.Allocator,
    sources: *std.ArrayList(Source),
    position: usize,
    which: index.Index,
    prefix: index.Prefix,
    newest: *const index.Suffix,
    oldest: [8]u8,
) Error!void {
    const cursor = lmdb.Cursor.init(try database(txn, which.name())) catch return error.Backend;
    errdefer cursor.deinit();
    try sources.append(arena, .{ .filter = position, .input = .{ .cursor = .{
        .cursor = cursor,
        .prefix = prefix,
        .start = .init(prefix, newest),
        .oldest = oldest,
    } } });
}

const Choice = union(enum) {
    ids,
    author_kind,
    tag: usize,
    author,
    kind,
    created_at,

    fn of(filter: Filter) Choice {
        if (filter.ids != null) return .ids;
        if (filter.authors) |authors| if (filter.kinds) |kinds_list| {
            if (authors.len * kinds_list.len <= max_prefixes_per_filter) return .author_kind;
        };
        if (filter.tags) |tag_filters| {
            var best: ?usize = null;
            for (tag_filters, 0..) |tag_filter, position| {
                if (best == null or tag_filter.values.len < tag_filters[best.?].values.len) best = position;
            }
            if (best) |position| if (tag_filters[position].values.len <= max_prefixes_per_filter) return .{ .tag = position };
        }
        if (filter.authors) |authors| if (authors.len <= max_prefixes_per_filter) return .author;
        if (filter.kinds) |kinds_list| if (kinds_list.len <= max_prefixes_per_filter) return .kind;
        return .created_at;
    }
};

pub const Lmdb = struct {
    gpa: std.mem.Allocator,
    env: lmdb.Environment,
    max_scan: usize,

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

        createTables(env) catch return error.Backend;
        return .{ .gpa = gpa, .env = env, .max_scan = options.max_scan };
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

        _ = self;
        const local_id = try nextLocalId(txn);
        const key = encodeLocalId(local_id);

        (try database(txn, events_db)).set(&key, buffer[0..size]) catch return error.Backend;
        try writeIndexes(txn, event, &key);

        const meta = lmdb.Database.open(txn, meta_db, .{ .create = true }) catch
            return error.Backend;
        const next = encodeLocalId(local_id + 1);
        meta.set(next_local_id_key, &next) catch return error.Backend;
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

    const vtable: Store.VTable = .{ .put = putErased, .putBatch = putBatchErased, .query = queryErased };

    fn putErased(ptr: *anyopaque, event: *const Event) StoreError!PutResult {
        const self: *Lmdb = @ptrCast(@alignCast(ptr));
        return self.put(event) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Backend,
        };
    }

    fn putBatchErased(ptr: *anyopaque, events: []const Event, results: []PutResult, local_ids: ?[]u64) StoreError!void {
        const self: *Lmdb = @ptrCast(@alignCast(ptr));
        return self.putBatch(events, results, local_ids) catch |err| switch (err) {
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
        var result: PutResult = undefined;
        try self.putBatch(event[0..1], (&result)[0..1], null);
        return result;
    }

    fn putBatch(self: *Lmdb, events: []const Event, results: []PutResult, local_ids: ?[]u64) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();

        const txn = lmdb.Transaction.init(self.env, .{ .mode = .ReadWrite }) catch
            return error.Backend;
        {
            errdefer txn.abort();
            for (events, results, 0..) |*event, *result, position| {
                _ = arena_state.reset(.retain_capacity);
                const allocated = try nextLocalId(txn);
                result.* = try self.insert(txn, arena_state.allocator(), event);
                if (local_ids) |ids| ids[position] = if (result.* == .stored) allocated else 0;
            }
        }
        try commit(txn);
    }

    fn insert(self: *Lmdb, txn: lmdb.Transaction, arena: std.mem.Allocator, event: *const Event) Error!PutResult {
        std.debug.assert(kinds.classify(event.kind) != .ephemeral);
        if (try self.contains(txn, &event.id)) return .duplicate;
        if (((try database(txn, deleted_db)).get(&event.id) catch return error.Backend) != null) return .deleted;

        if (Coordinate.of(event)) |coordinate| {
            if (try deletedUntil(txn, &coordinate)) |until| {
                if (event.created_at <= until) return .deleted;
            }
            if (try self.occupant(txn, arena, &coordinate)) |incumbent| {
                if (!kinds.supersedes(event, &incumbent.event)) return .outdated;
                try remove(txn, &incumbent);
            }
        }

        const size = record.encodedSize(event) catch return error.Backend;
        const buffer = try arena.alloc(u8, size);
        _ = try self.append(txn, buffer, event);
        if (event.kind == kinds.deletion) try self.applyDeletion(txn, arena, event);
        return .stored;
    }

    const Stored = struct { local_id: u64, event: Event };

    fn occupant(self: *Lmdb, txn: lmdb.Transaction, arena: std.mem.Allocator, coordinate: *const Coordinate) Error!?Stored {
        const value = ((try database(txn, coordinate.db)).get(coordinate.key()) catch return error.Backend) orelse return null;
        return try self.storedAt(txn, arena, value);
    }

    fn storedAt(self: *Lmdb, txn: lmdb.Transaction, arena: std.mem.Allocator, value: []const u8) Error!Stored {
        if (value.len != 8) return error.Corrupt;
        const local_id = std.mem.readInt(u64, value[0..8], .big);
        const event = (try self.read(txn, arena, local_id)) orelse return error.Corrupt;
        return .{ .local_id = local_id, .event = event };
    }

    fn applyDeletion(self: *Lmdb, txn: lmdb.Transaction, arena: std.mem.Allocator, request: *const Event) Error!void {
        for (request.tags) |tag| switch (kinds.Target.of(tag) orelse continue) {
            .id => |id| {
                const value = ((try database(txn, by_id_db)).get(&id) catch return error.Backend) orelse continue;
                const target = try self.storedAt(txn, arena, value);
                if (target.event.kind == kinds.deletion or !std.mem.eql(u8, &target.event.pubkey, &request.pubkey)) continue;
                (try database(txn, deleted_db)).set(&id, "") catch return error.Backend;
                try remove(txn, &target);
            },
            .address => |address| {
                if (!std.mem.eql(u8, &address.pubkey, &request.pubkey)) continue;
                const coordinate = Coordinate.from(&address.pubkey, address.kind, address.d) orelse continue;
                if (try self.occupant(txn, arena, &coordinate)) |target| {
                    if (target.event.created_at <= request.created_at) try remove(txn, &target);
                }
                const until = @max(request.created_at, (try deletedUntil(txn, &coordinate)) orelse std.math.minInt(i64));
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &bytes, until, .big);
                (try database(txn, deleted_address_db)).set(coordinate.key(), &bytes) catch return error.Backend;
            },
        };
    }

    fn query(self: *Lmdb, filters: []const Filter, sink: Sink) (Error || Sink.Abort)!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const remaining = try arena.alloc(u64, filters.len);
        var pending: usize = 0;
        for (filters, remaining) |filter, *left| {
            left.* = filter.limit orelse std.math.maxInt(u64);
            if (left.* != 0) pending += 1;
        }
        const txn = lmdb.Transaction.init(self.env, .{ .mode = .ReadOnly }) catch
            return error.Backend;
        defer txn.abort();

        if (sink.watermark) |watermark| watermark.* = try snapshotWatermark(txn);
        if (pending == 0) return;

        var sources: std.ArrayList(Source) = .empty;
        defer for (sources.items) |*source| source.deinit();
        for (filters, remaining, 0..) |filter, left, position| {
            if (left == 0) continue;
            try plan(txn, arena, filter, position, &sources);
        }
        for (sources.items) |*source| try source.advance();

        var event_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer event_arena.deinit();
        var scanned: usize = 0;
        while (pending != 0 and scanned < self.max_scan) {
            var next: ?Head = null;
            for (sources.items) |source| {
                const head = source.head orelse continue;
                if (remaining[source.filter] == 0) continue;
                if (next == null or Head.lessThan({}, head, next.?)) next = head;
            }
            const chosen = next orelse break;
            for (sources.items) |*source| {
                const head = source.head orelse continue;
                if (!std.mem.eql(u8, &head.tail, &chosen.tail)) continue;
                try source.advance();
                scanned += 1;
            }

            _ = event_arena.reset(.retain_capacity);
            const event = (try self.read(txn, event_arena.allocator(), chosen.local_id)) orelse
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

    fn plan(
        txn: lmdb.Transaction,
        arena: std.mem.Allocator,
        filter: Filter,
        position: usize,
        sources: *std.ArrayList(Source),
    ) Error!void {
        const newest = index.suffix(filter.until orelse std.math.maxInt(i64), &([_]u8{0} ** 32));
        const oldest = index.descendingTime(filter.since orelse std.math.minInt(i64));
        switch (Choice.of(filter)) {
            .ids => {
                const ids = try arena.dupe([32]u8, filter.ids.?);
                std.mem.sort([32]u8, ids, {}, idLessThan);
                var heads: std.ArrayList(Head) = .empty;
                const by_id = try database(txn, by_id_db);
                const events = try database(txn, events_db);
                for (ids, 0..) |*id, position_in_ids| {
                    if (position_in_ids != 0 and std.mem.eql(u8, id, &ids[position_in_ids - 1])) continue;
                    const value = (by_id.get(id) catch return error.Backend) orelse continue;
                    if (value.len != 8) return error.Corrupt;
                    const bytes = (events.get(value) catch return error.Backend) orelse return error.Corrupt;
                    const created_at = record.createdAt(bytes) catch return error.Corrupt;
                    try heads.append(arena, .{ .tail = index.suffix(created_at, id), .local_id = std.mem.readInt(u64, value[0..8], .big) });
                }
                std.mem.sort(Head, heads.items, {}, Head.lessThan);
                try sources.append(arena, .{ .filter = position, .input = .{ .list = .{ .items = heads.items } } });
            },
            .author_kind => for (filter.authors.?) |*pubkey| for (filter.kinds.?) |value| {
                try addCursor(txn, arena, sources, position, .by_author_kind, .authorKind(pubkey, value), &newest, oldest);
            },
            .tag => |which| {
                const tag_filter = filter.tags.?[which];
                for (tag_filter.values) |value| {
                    try addCursor(txn, arena, sources, position, .by_tag, .tag(tag_filter.letter, value), &newest, oldest);
                }
            },
            .author => for (filter.authors.?) |*pubkey| {
                try addCursor(txn, arena, sources, position, .by_author, .author(pubkey), &newest, oldest);
            },
            .kind => for (filter.kinds.?) |value| {
                try addCursor(txn, arena, sources, position, .by_kind, .kind(value), &newest, oldest);
            },
            .created_at => try addCursor(txn, arena, sources, position, .by_created_at, .none(), &newest, oldest),
        }
    }
};

/// Creates every table, because a read-only transaction cannot.
fn createTables(env: lmdb.Environment) !void {
    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    {
        errdefer txn.abort();
        for ([_][*:0]const u8{ meta_db, events_db, by_id_db, by_replaceable_db, by_address_db, deleted_db, deleted_address_db }) |name| {
            _ = try lmdb.Database.open(txn, name, .{ .create = true });
        }
        for (std.enums.values(index.Index)) |which| _ = try lmdb.Database.open(txn, which.name(), .{ .create = true });
        _ = try nextLocalId(txn);
    }
    try commit(txn);
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
        txn.set("k", "v") catch |err| {
            txn.abort();
            return err;
        };
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
    const local_id = backend.append(txn, buffer, event) catch |err| {
        txn.abort();
        return err;
    };
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

    fn idAt(self: Collector, position: usize) u8 {
        return self.ids[position][0];
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

    for ([_][*:0]const u8{
        events_db,
        by_id_db,
        by_replaceable_db,
        index.Index.by_created_at.name(),
        index.Index.by_author.name(),
        index.Index.by_kind.name(),
        index.Index.by_author_kind.name(),
    }) |name| {
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

const memory = @import("memory.zig");

const IdCollector = struct {
    gpa: std.mem.Allocator,
    ids: std.ArrayList([32]u8) = .empty,

    fn sink(self: *IdCollector) Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) Sink.Abort!void {
        const self: *IdCollector = @ptrCast(@alignCast(ptr));
        self.ids.append(self.gpa, event.id) catch return error.Abort;
    }
};

fn randomEvent(random: std.Random, arena: std.mem.Allocator, authors: []const [32]u8) !Event {
    const kind_choices = [_]u16{ 1, 1, 1, 7, 0, 3, 10002, 30023, 30000, 40000, 5 };
    const letters = [_][]const u8{ "e", "p", "t", "d" };
    const values = [_][]const u8{ "", "a", "b", "c" };

    const tags = try arena.alloc(nostr.event.Tag, random.uintLessThan(usize, 4));
    for (tags) |*tag| {
        const fields = try arena.alloc([]const u8, 1 + random.uintLessThan(usize, 2));
        fields[0] = letters[random.uintLessThan(usize, letters.len)];
        if (fields.len > 1) fields[1] = values[random.uintLessThan(usize, values.len)];
        tag.* = fields;
    }
    var event: Event = .{
        .id = undefined,
        .pubkey = authors[random.uintLessThan(usize, authors.len)],
        .created_at = random.intRangeAtMost(i64, -3, 40),
        .kind = kind_choices[random.uintLessThan(usize, kind_choices.len)],
        .tags = tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
    random.bytes(&event.id);
    event.id[0] &= 0x0f;
    return event;
}

fn randomDeletion(random: std.Random, arena: std.mem.Allocator, authors: []const [32]u8, published: []const Event) !Event {
    var request = try randomEvent(random, arena, authors);
    request.kind = kinds.deletion;
    const tags = try arena.alloc(nostr.event.Tag, 1 + random.uintLessThan(usize, 3));
    for (tags) |*tag| {
        const target = published[random.uintLessThan(usize, published.len)];
        if (random.boolean()) {
            tag.* = try arena.dupe([]const u8, &.{ "e", try arena.dupe(u8, &std.fmt.bytesToHex(target.id, .lower)) });
        } else {
            const address = try std.fmt.allocPrint(arena, "{d}:{s}:{s}", .{
                target.kind,
                std.fmt.bytesToHex(target.pubkey, .lower),
                kinds.dValue(&target),
            });
            tag.* = try arena.dupe([]const u8, &.{ "a", address });
        }
    }
    request.tags = tags;
    if (random.boolean()) request.pubkey = published[random.uintLessThan(usize, published.len)].pubkey;
    return request;
}

fn randomFilter(random: std.Random, arena: std.mem.Allocator, authors: []const [32]u8, stored: []const Event) !Filter {
    var filter: Filter = .{};
    if (random.uintLessThan(u8, 6) == 0 and stored.len != 0) {
        const ids = try arena.alloc([32]u8, 1 + random.uintLessThan(usize, 4));
        for (ids) |*id| id.* = stored[random.uintLessThan(usize, stored.len)].id;
        filter.ids = ids;
    }
    if (random.boolean()) {
        const picked = try arena.alloc([32]u8, random.uintLessThan(usize, 3));
        for (picked) |*author| author.* = authors[random.uintLessThan(usize, authors.len)];
        filter.authors = picked;
    }
    if (random.boolean()) {
        const picked = try arena.alloc(u16, 1 + random.uintLessThan(usize, 3));
        for (picked) |*value| value.* = ([_]u16{ 1, 7, 0, 30023, 40000 })[random.uintLessThan(usize, 5)];
        filter.kinds = picked;
    }
    if (random.uintLessThan(u8, 3) == 0) {
        const values = try arena.alloc([]const u8, 1 + random.uintLessThan(usize, 2));
        for (values) |*value| value.* = ([_][]const u8{ "", "a", "b", "c" })[random.uintLessThan(usize, 4)];
        const tag_filters = try arena.alloc(nostr.filter.TagFilter, 1);
        tag_filters[0] = .{ .letter = ("ept")[random.uintLessThan(usize, 3)], .values = values };
        filter.tags = tag_filters;
    }
    if (random.boolean()) filter.since = random.intRangeAtMost(i64, -3, 40);
    if (random.boolean()) filter.until = random.intRangeAtMost(i64, -3, 40);
    if (random.uintLessThan(u8, 4) != 0) filter.limit = random.uintLessThan(u32, 12);
    return filter;
}

test "the LMDB planner agrees with brute force over the memory store" {
    for (0..12) |seed| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var oracle = memory.Memory.init(testing.allocator, testing.io);
        defer oracle.deinit();

        var authors: [3][32]u8 = undefined;
        for (&authors, 0..) |*author, position| author.* = [_]u8{@intCast(position + 1)} ** 32;

        var published: std.ArrayList(Event) = .empty;
        while (published.items.len < 250) {
            const batch = try arena.alloc(Event, 1 + random.uintLessThan(usize, 16));
            for (batch) |*event| {
                event.* = if (published.items.len != 0 and random.uintLessThan(u8, 10) == 0)
                    published.items[random.uintLessThan(usize, published.items.len)]
                else if (published.items.len != 0 and random.uintLessThan(u8, 12) == 0)
                    try randomDeletion(random, arena, &authors, published.items)
                else
                    try randomEvent(random, arena, &authors);
            }
            const want = try arena.alloc(PutResult, batch.len);
            const got = try arena.alloc(PutResult, batch.len);
            const want_ids = try arena.alloc(u64, batch.len);
            const got_ids = try arena.alloc(u64, batch.len);
            try oracle.store().putBatch(batch, want, want_ids);
            try fixture.backend.store().putBatch(batch, got, got_ids);
            try testing.expectEqualSlices(PutResult, want, got);
            try testing.expectEqualSlices(u64, want_ids, got_ids);
            try published.appendSlice(arena, batch);
        }

        for (0..150) |_| {
            const filters = try arena.alloc(Filter, 1 + random.uintLessThan(usize, 3));
            for (filters) |*filter| filter.* = try randomFilter(random, arena, &authors, published.items);

            var want: IdCollector = .{ .gpa = arena };
            var want_watermark: u64 = 0;
            var want_sink = want.sink();
            want_sink.watermark = &want_watermark;
            try oracle.store().query(filters, want_sink);
            var got: IdCollector = .{ .gpa = arena };
            var got_watermark: u64 = 0;
            var got_sink = got.sink();
            got_sink.watermark = &got_watermark;
            try fixture.backend.store().query(filters, got_sink);
            try testing.expectEqualSlices([32]u8, want.ids.items, got.ids.items);
            try testing.expectEqual(want_watermark, got_watermark);
        }
    }
}

test "the scan budget ends a query early" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);
    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{ .max_scan = 3 });
    defer backend.close();

    for (0..10) |position| {
        const event = kindEvent(@intCast(position + 1), 1700000000 + @as(i64, @intCast(position)), 1);
        _ = try backend.store().put(&event);
    }
    var collector: Collector = .{};
    try backend.store().query(&.{.{ .kinds = &.{7} }}, collector.sink());
    try testing.expectEqual(@as(usize, 0), collector.len);
    try backend.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(usize, 3), collector.len);
}

test "a deletion holds across a restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    const note = kindEvent(1, 1700000000, 1);
    {
        var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer backend.close();
        _ = try backend.store().put(&note);
        var request = kindEvent(2, 1700000001, kinds.deletion);
        request.tags = &.{&.{ "e", &std.fmt.bytesToHex(note.id, .lower) }};
        _ = try backend.store().put(&request);
    }

    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();
    try testing.expectEqual(PutResult.deleted, try backend.store().put(&note));
}

test "the watermark is the newest local id a query's snapshot holds" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var watermark: u64 = 99;
    var collector: Collector = .{};
    var sink = collector.sink();
    sink.watermark = &watermark;
    try fixture.backend.store().query(&.{.{}}, sink);
    try testing.expectEqual(@as(u64, 0), watermark);

    for ([_]u8{ 1, 2, 3 }) |id_byte| {
        const event = kindEvent(id_byte, 1700000000, 1);
        _ = try fixture.backend.store().put(&event);
    }
    try fixture.backend.store().query(&.{.{ .limit = 0 }}, sink);
    try testing.expectEqual(@as(u64, 3), watermark);
}

test "a query on a store that has never been written answers nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var collector: Collector = .{};
    try fixture.backend.store().query(&.{ .{}, .{ .kinds = &.{1} }, .{ .authors = &.{[_]u8{1} ** 32} } }, collector.sink());
    try testing.expectEqual(@as(usize, 0), collector.len);
}

test "two handles on one environment never reuse a local id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var first = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer first.close();
    var second = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer second.close();

    for (0..3) |round| {
        const base: u8 = @intCast(round * 2 + 1);
        const at: i64 = 1700000000 + @as(i64, base);
        try testing.expectEqual(PutResult.stored, try first.store().put(&kindEvent(base, at, 1)));
        try testing.expectEqual(PutResult.stored, try second.store().put(&kindEvent(base + 1, at + 1, 1)));
    }

    var collector: Collector = .{};
    try first.store().query(&.{.{}}, collector.sink());
    try testing.expectEqual(@as(usize, 6), collector.len);
    for (0..6) |position| try testing.expectEqual(@as(u8, @intCast(6 - position)), collector.idAt(position));
}

test "an ids query reads each event once, however often its id repeats" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);
    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    var tags: [2000]nostr.event.Tag = undefined;
    for (&tags) |*tag| tag.* = &.{ "t", "x" };
    var note = kindEvent(1, 1700000000, 1);
    note.tags = &tags;
    _ = try backend.store().put(&note);

    var ids: [1000][32]u8 = undefined;
    for (&ids) |*id| id.* = note.id;
    var measured = testing.FailingAllocator.init(testing.allocator, .{});
    backend.gpa = measured.allocator();
    defer backend.gpa = testing.allocator;
    var collector: Collector = .{};
    try backend.store().query(&.{.{ .ids = &ids, .limit = 1 }}, collector.sink());
    try testing.expectEqual(@as(usize, 1), collector.len);
    try testing.expect(measured.allocated_bytes < 1024 * 1024);
}

test "a commit the disk refuses leaves the store answering, not crashing" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);
    var backend = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer backend.close();

    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.XFSZ, &ignore, &previous_action);
    defer std.posix.sigaction(.XFSZ, &previous_action, null);
    const previous_limit = try std.posix.getrlimit(.FSIZE);
    try std.posix.setrlimit(.FSIZE, .{ .cur = 128 * 1024, .max = previous_limit.max });
    var limited = true;
    defer if (limited) std.posix.setrlimit(.FSIZE, previous_limit) catch {};

    const content = "z" ** 4096;
    var refused: usize = 0;
    var id: u8 = 1;
    while (id < 200 and refused < 5) : (id += 1) {
        var event = kindEvent(id, 1700000000 + @as(i64, id), 1);
        event.content = content;
        _ = backend.store().put(&event) catch {
            refused += 1;
        };
    }
    try testing.expectEqual(@as(usize, 5), refused);

    try std.posix.setrlimit(.FSIZE, previous_limit);
    limited = false;
    for (0..20) |_| {
        var event = kindEvent(id, 1700000000 + @as(i64, id), 1);
        event.content = content;
        try testing.expectEqual(PutResult.stored, try backend.store().put(&event));
        id += 1;
    }
    var collector: Collector = .{ .stop_after = 1 };
    try testing.expectError(error.Abort, backend.store().query(&.{.{}}, collector.sink()));
    try testing.expectEqual(id - 1, collector.idAt(0));
}
