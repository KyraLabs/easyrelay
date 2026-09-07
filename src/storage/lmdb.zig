//! The LMDB backend: easyrelay's own schema, not a third party's.
//!
//! The data model this implements is docs/storage.md, and the reasoning behind
//! writing it here rather than taking one is
//! docs/adr/0010-first-party-lmdb-store.md. Nothing from `lmdb` appears above
//! this file (docs/adr/0008-store-abstraction-boundary.md).
//!
//! This file currently owns the environment, the `events` table and the local
//! id counter. The indexes, the write path and the query planner arrive with
//! the commits that need them.

const std = @import("std");
const lmdb = @import("lmdb");
const nostr = @import("nostr");

const record = @import("record.zig");

const Event = nostr.event.Event;

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

pub const Lmdb = struct {
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
        return .{ .env = env, .next_local_id = next_local_id };
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
        const events = lmdb.Database.open(txn, events_db, .{ .create = true }) catch
            return error.Backend;
        const key = encodeLocalId(local_id);
        events.set(&key, buffer[0..size]) catch return error.Backend;

        const meta = lmdb.Database.open(txn, meta_db, .{ .create = true }) catch
            return error.Backend;
        const next = encodeLocalId(local_id + 1);
        meta.set(next_local_id_key, &next) catch return error.Backend;

        self.next_local_id = local_id + 1;
        return local_id;
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

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    store.close();

    var opened = try std.Io.Dir.cwd().openDir(testing.io, data_dir, .{});
    opened.close(testing.io);
}

test "open twice over the same directory reaches the same environment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &buffer);

    {
        var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer store.close();

        const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadWrite });
        errdefer txn.abort();
        try txn.set("k", "v");
        try txn.commit();
    }

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadOnly });
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

fn appendOne(store: *Lmdb, buffer: []u8, event: *const Event) !u64 {
    const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadWrite });
    errdefer txn.abort();
    const local_id = try store.append(txn, buffer, event);
    try txn.commit();
    return local_id;
}

test "local ids start at one and increase with insertion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    var buffer: [4096]u8 = undefined;
    const first = testEvent(1, 1700000000);
    const second = testEvent(2, 1700000100);

    try testing.expectEqual(first_local_id, try appendOne(&store, &buffer, &first));
    try testing.expectEqual(first_local_id + 1, try appendOne(&store, &buffer, &second));
}

test "an appended event reads back through its local id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    const tags = [_]nostr.event.Tag{&.{ "d", "value" }};
    var event = testEvent(7, 1700000000);
    event.tags = &tags;
    event.content = "stored";

    var buffer: [4096]u8 = undefined;
    const local_id = try appendOne(&store, &buffer, &event);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadOnly });
    defer txn.abort();

    const read_back = (try store.read(txn, arena.allocator(), local_id)).?;
    try testing.expectEqualSlices(u8, &event.id, &read_back.id);
    try testing.expectEqualStrings("stored", read_back.content);
    try testing.expectEqualStrings("value", read_back.tags[0][1]);
}

test "reading a local id that was never assigned gives null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadOnly });
    defer txn.abort();

    try testing.expectEqual(@as(?Event, null), try store.read(txn, arena.allocator(), 99));
}

test "the local id counter survives a reopen and does not restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var buffer: [4096]u8 = undefined;
    var last: u64 = undefined;
    {
        var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
        defer store.close();
        const event = testEvent(1, 1700000000);
        _ = try appendOne(&store, &buffer, &event);
        last = try appendOne(&store, &buffer, &testEvent(2, 1700000100));
    }

    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    const event = testEvent(3, 1700000200);
    try testing.expectEqual(last + 1, try appendOne(&store, &buffer, &event));
}

test "an aborted transaction assigns no id that a later append reuses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_dir = try tmpPath(&tmp, &path_buffer);

    var buffer: [4096]u8 = undefined;
    var store = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store.close();

    const event = testEvent(1, 1700000000);
    {
        const txn = try lmdb.Transaction.init(store.env, .{ .mode = .ReadWrite });
        _ = try store.append(txn, &buffer, &event);
        txn.abort();
    }

    // The in-memory counter advanced with the append that was rolled back, so
    // the id it handed out is skipped rather than handed out twice. Skipping is
    // free; reuse would make the watermark in docs/roadmap.md wrong.
    var store_after = try Lmdb.open(testing.allocator, testing.io, data_dir, .{});
    defer store_after.close();

    try testing.expectEqual(first_local_id, try appendOne(&store_after, &buffer, &event));
}
