const std = @import("std");

const frame = @import("../transport/frame.zig");

/// Frames waiting for a connection's sender thread, bounded by `limit` bytes.
///
/// Producers that must not wait on a client — the writer thread's fan-out and replies — use
/// `queue`, which breaks the connection when the frame does not fit. The connection's own thread
/// uses `send`, which waits for room: its client is the one being slow, and waiting stalls nobody
/// else. `send` stops at half the limit, so a large `REQ` streaming to a slow reader leaves the
/// other half for live events instead of turning the next one into a disconnect.
pub const Outbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    limit: usize,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    pending: std.ArrayList(u8) = .empty,
    /// Bytes taken by the sender and not yet written; they still count against `limit`.
    in_flight: usize = 0,
    state: State = .open,

    pub const State = enum { open, finishing, broken };

    pub const Error = error{
        /// The connection is closing or has failed; nothing more will be written.
        Closed,
        /// The frame did not fit and the connection is now broken.
        Overflow,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, limit: usize) Outbox {
        return .{ .gpa = gpa, .io = io, .limit = limit };
    }

    pub fn deinit(self: *Outbox) void {
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    /// Waits for room. A frame larger than `limit` is still accepted once nothing else is queued,
    /// so a limit below the largest message cannot wedge a connection.
    pub fn send(self: *Outbox, opcode: frame.Opcode, payload: []const u8) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const size = encodedSize(payload.len);
        while (self.state == .open and self.used() != 0 and self.used() + size > self.limit / 2) {
            self.changed.waitUncancelable(self.io, &self.mutex);
        }
        try self.append(opcode, payload);
    }

    /// Never waits.
    pub fn queue(self: *Outbox, opcode: frame.Opcode, payload: []const u8) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .open and self.used() != 0 and self.used() + encodedSize(payload.len) > self.limit) {
            self.breakLocked();
            return error.Overflow;
        }
        try self.append(opcode, payload);
    }

    /// For the sender thread: marks the previous batch written, then swaps the pending bytes into
    /// `batch`. False means there is nothing more to write, ever.
    pub fn take(self: *Outbox, batch: *std.ArrayList(u8)) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(batch.items.len == 0);
        if (self.in_flight != 0) {
            self.in_flight = 0;
            self.changed.broadcast(self.io);
        }
        while (self.state == .open and self.pending.items.len == 0) self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.state == .broken or self.pending.items.len == 0) return false;
        std.mem.swap(std.ArrayList(u8), batch, &self.pending);
        self.in_flight = batch.items.len;
        return true;
    }

    /// No more frames will be added; the sender writes what is queued and stops.
    pub fn finish(self: *Outbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state == .open) self.state = .finishing;
        self.changed.broadcast(self.io);
    }

    /// The socket failed; wakes anyone waiting for room.
    pub fn fail(self: *Outbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.breakLocked();
    }

    pub fn isBroken(self: *Outbox) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .broken;
    }

    fn used(self: *const Outbox) usize {
        return self.pending.items.len + self.in_flight;
    }

    fn breakLocked(self: *Outbox) void {
        self.state = .broken;
        self.pending.clearAndFree(self.gpa);
        self.changed.broadcast(self.io);
    }

    fn append(self: *Outbox, opcode: frame.Opcode, payload: []const u8) Error!void {
        if (self.state != .open) return error.Closed;
        var writer: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.pending);
        defer self.pending = writer.toArrayList();
        frame.writeFrame(&writer.writer, opcode, payload, null) catch {
            self.breakLocked();
            return error.Overflow;
        };
        self.changed.broadcast(self.io);
    }
};

fn encodedSize(payload_length: usize) usize {
    const header: usize = if (payload_length < 126) 2 else if (payload_length <= std.math.maxInt(u16)) 4 else 10;
    return header + payload_length;
}

const testing = std.testing;

test "queued frames come out in order, framed" {
    var outbox = Outbox.init(testing.allocator, testing.io, 1024);
    defer outbox.deinit();
    try outbox.queue(.text, "one");
    try outbox.send(.text, "two");

    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);
    try testing.expect(outbox.take(&batch));
    try testing.expectEqualSlices(u8, "\x81\x03one\x81\x03two", batch.items);
}

test "a frame that does not fit breaks the connection instead of buffering" {
    var outbox = Outbox.init(testing.allocator, testing.io, 8);
    defer outbox.deinit();
    try outbox.queue(.text, "abc");
    try testing.expectError(error.Overflow, outbox.queue(.text, "defgh"));
    try testing.expect(outbox.isBroken());
    try testing.expectError(error.Closed, outbox.queue(.text, "x"));

    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);
    try testing.expect(!outbox.take(&batch));
}

test "a frame larger than the limit is accepted when nothing else is queued" {
    var outbox = Outbox.init(testing.allocator, testing.io, 4);
    defer outbox.deinit();
    try outbox.queue(.text, "larger than four");
    try testing.expect(!outbox.isBroken());
}

test "bytes taken by the sender still count until it comes back" {
    var outbox = Outbox.init(testing.allocator, testing.io, 8);
    defer outbox.deinit();
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);

    try outbox.queue(.text, "abcd");
    try testing.expect(outbox.take(&batch));
    try testing.expectError(error.Overflow, outbox.queue(.text, "efgh"));
}

test "finishing drains what is queued and then stops" {
    var outbox = Outbox.init(testing.allocator, testing.io, 1024);
    defer outbox.deinit();
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);

    try outbox.queue(.text, "last");
    outbox.finish();
    try testing.expectError(error.Closed, outbox.queue(.text, "late"));
    try testing.expect(outbox.take(&batch));
    batch.clearRetainingCapacity();
    try testing.expect(!outbox.take(&batch));
}

const Drainer = struct {
    outbox: *Outbox,
    written: usize = 0,

    fn run(self: *Drainer) void {
        var batch: std.ArrayList(u8) = .empty;
        defer batch.deinit(testing.allocator);
        while (self.outbox.take(&batch)) {
            self.written += batch.items.len;
            batch.clearRetainingCapacity();
        }
    }
};

test "send waits for the sender to make room rather than failing" {
    var outbox = Outbox.init(testing.allocator, testing.io, 32);
    defer outbox.deinit();
    var drainer: Drainer = .{ .outbox = &outbox };
    const thread = try std.Thread.spawn(.{}, Drainer.run, .{&drainer});

    for (0..100) |_| try outbox.send(.text, "0123456789");
    outbox.finish();
    thread.join();
    try testing.expectEqual(@as(usize, 100 * 12), drainer.written);
}

test "a failed socket releases a producer waiting for room" {
    var outbox = Outbox.init(testing.allocator, testing.io, 8);
    defer outbox.deinit();
    try outbox.queue(.text, "abcd");

    const Failer = struct {
        fn run(target: *Outbox) void {
            std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
            target.fail();
        }
    };
    const thread = try std.Thread.spawn(.{}, Failer.run, .{&outbox});
    defer thread.join();
    try testing.expectError(error.Closed, outbox.send(.text, "efgh"));
}

test "send leaves half the limit free for queued frames" {
    var outbox = Outbox.init(testing.allocator, testing.io, 24);
    defer outbox.deinit();
    try outbox.send(.text, "0123456789");
    try outbox.queue(.text, "0123456789");
    try testing.expect(!outbox.isBroken());
    try testing.expectError(error.Overflow, outbox.queue(.text, "x"));
}
