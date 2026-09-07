//! The LMDB backend: easyrelay's own schema, not a third party's.
//!
//! The data model this implements is docs/storage.md, and the reasoning behind
//! writing it here rather than taking one is
//! docs/adr/0010-first-party-lmdb-store.md. Nothing from `lmdb` appears above
//! this file (docs/adr/0008-store-abstraction-boundary.md).
//!
//! This file currently owns the environment's lifecycle. The schema, the write
//! path and the query planner arrive with the commits that need them.

const std = @import("std");
const lmdb = @import("lmdb");

pub const Error = error{
    OutOfMemory,
    /// The data directory could not be created.
    DataDirectory,
    /// LMDB refused to open the environment. The commonest cause by far is a
    /// `map_size` the address space cannot satisfy.
    Backend,
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

pub const Lmdb = struct {
    env: lmdb.Environment,

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
        }) catch return error.Backend;

        return .{ .env = env };
    }

    pub fn close(self: *Lmdb) void {
        self.env.deinit();
        self.* = undefined;
    }
};

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
