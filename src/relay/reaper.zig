const std = @import("std");

const store = @import("../storage/store.zig");

const log = std.log.scoped(.reaper);

pub const Reaper = struct {
    io: std.Io,
    store: store.Store,
    interval_s: u32,
    /// Per write transaction, so a sweep never holds the write lock for long.
    batch: usize = 1000,
    stopping: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    pub fn start(self: *Reaper) !void {
        std.debug.assert(self.thread == null and self.interval_s > 0);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *Reaper) void {
        const thread = self.thread orelse return;
        self.stopping.set(self.io);
        thread.join();
        self.thread = null;
    }

    pub fn sweep(self: *Reaper, now: i64) store.Error!usize {
        var total: usize = 0;
        while (!self.stopping.isSet()) {
            const removed = try self.store.reap(now, self.batch);
            total += removed;
            if (removed < self.batch) break;
        }
        return total;
    }

    fn run(self: *Reaper) void {
        const interval: std.Io.Clock.Duration = .{ .raw = .fromSeconds(self.interval_s), .clock = .awake };
        var due: std.Io.Clock.Timestamp = .fromNow(self.io, interval);
        while (true) {
            self.stopping.waitTimeout(self.io, .{ .deadline = due }) catch {};
            if (self.stopping.isSet()) return;
            if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.lt, due)) continue;
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (self.sweep(now)) |removed| {
                if (removed != 0) log.info("removed {d} expired events", .{removed});
            } else |err| log.warn("the expiration sweep failed: {t}", .{err});
            due = .fromNow(self.io, interval);
        }
    }
};

const testing = std.testing;
const memory = @import("../storage/memory.zig");
const nostr = @import("nostr");

fn expiring(arena: std.mem.Allocator, id_byte: u8, at: []const u8) !nostr.event.Event {
    const tags = try arena.alloc(nostr.event.Tag, 1);
    tags[0] = try arena.dupe([]const u8, &.{ "expiration", at });
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{1} ** 32,
        .created_at = 1_700_000_000,
        .kind = 1,
        .tags = tags,
        .content = "",
        .sig = [_]u8{0} ** 64,
    };
}

test "a sweep removes what has expired, in batches, and leaves the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var backing = memory.Memory.init(testing.allocator, testing.io);
    defer backing.deinit();
    for (0..5) |position| _ = try backing.store().put(&try expiring(arena, @intCast(position + 1), "100"));
    _ = try backing.store().put(&try expiring(arena, 9, "300"));

    var reaper: Reaper = .{ .io = testing.io, .store = backing.store(), .interval_s = 60, .batch = 2 };
    try testing.expectEqual(@as(usize, 5), try reaper.sweep(200));
    try testing.expectEqual(@as(usize, 0), try reaper.sweep(200));
    try testing.expectEqual(@as(usize, 1), try reaper.sweep(300));
}

test "a started reaper stops promptly" {
    var backing = memory.Memory.init(testing.allocator, testing.io);
    defer backing.deinit();
    var reaper: Reaper = .{ .io = testing.io, .store = backing.store(), .interval_s = 3600 };
    try reaper.start();
    const started = std.Io.Timestamp.now(testing.io, .awake);
    reaper.stop();
    try testing.expect(started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds() < 1000);
}
