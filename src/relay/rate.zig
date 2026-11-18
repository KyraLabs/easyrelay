const std = @import("std");

/// A token bucket. Time is passed in, in nanoseconds on a monotonic clock, so tests control it.
pub const Bucket = struct {
    per_second: f64,
    capacity: f64,
    tokens: f64,
    last_ns: ?i96 = null,

    pub fn init(per_second: f64, burst: usize) Bucket {
        std.debug.assert(per_second > 0 and burst > 0);
        const capacity: f64 = @floatFromInt(burst);
        return .{ .per_second = per_second, .capacity = capacity, .tokens = capacity };
    }

    /// Callers read the clock before taking a shared bucket's lock, so times can arrive out of
    /// order; an earlier one refills nothing and does not move the bucket's clock back.
    pub fn take(self: *Bucket, now_ns: i96) bool {
        if (self.last_ns) |last| {
            const elapsed: f64 = @floatFromInt(@max(0, now_ns - last));
            self.tokens = @min(self.capacity, self.tokens + elapsed * self.per_second / std.time.ns_per_s);
            self.last_ns = @max(last, now_ns);
        } else {
            self.last_ns = now_ns;
        }
        if (self.tokens < 1) return false;
        self.tokens -= 1;
        return true;
    }
};

pub const Rule = struct {
    per_second: f64,
    burst: usize,

    pub fn bucket(self: Rule) Bucket {
        return .init(self.per_second, self.burst);
    }
};

pub const Limits = struct {
    events: ?Rule = .{ .per_second = 10, .burst = 50 },
    messages: ?Rule = .{ .per_second = 50, .burst = 100 },
    subscriptions: ?Rule = .{ .per_second = 1, .burst = 20 },
    author_events: ?Rule = .{ .per_second = 10, .burst = 50 },
};

/// One connection's buckets. Owned by the connection's thread; not shared.
pub const Connection = struct {
    events: ?Bucket,
    messages: ?Bucket,
    subscriptions: ?Bucket,

    pub fn init(limits: Limits) Connection {
        return .{
            .events = if (limits.events) |rule| rule.bucket() else null,
            .messages = if (limits.messages) |rule| rule.bucket() else null,
            .subscriptions = if (limits.subscriptions) |rule| rule.bucket() else null,
        };
    }

    pub fn message(self: *Connection, now_ns: i96) bool {
        return takeFrom(&self.messages, now_ns);
    }

    pub fn event(self: *Connection, now_ns: i96) bool {
        return takeFrom(&self.events, now_ns);
    }

    pub fn subscription(self: *Connection, now_ns: i96) bool {
        return takeFrom(&self.subscriptions, now_ns);
    }

    fn takeFrom(bucket: *?Bucket, now_ns: i96) bool {
        if (bucket.*) |*present| return present.take(now_ns);
        return true;
    }
};

/// Per-author buckets shared by every connection, in a fixed table so memory does not grow with
/// the number of authors. Authors are hashed into slots with a key chosen at startup; two authors
/// sharing a slot share a budget, which errs strict, and the key stops anyone from choosing a
/// pubkey that lands on someone else's slot.
pub const Authors = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    rule: Rule,
    key: [16]u8,
    slots: []Bucket,

    pub const slot_count = 4096;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, rule: Rule) error{OutOfMemory}!Authors {
        const slots = try gpa.alloc(Bucket, slot_count);
        for (slots) |*slot| slot.* = rule.bucket();
        var key: [16]u8 = undefined;
        io.random(&key);
        return .{ .io = io, .rule = rule, .key = key, .slots = slots };
    }

    pub fn deinit(self: *Authors, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn take(self: *Authors, pubkey: *const [32]u8, now_ns: i96) bool {
        const slot = std.crypto.auth.siphash.SipHash64(2, 4).toInt(pubkey, &self.key) % self.slots.len;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.slots[slot].take(now_ns);
    }
};

const testing = std.testing;
const second: i96 = std.time.ns_per_s;

test "a bucket allows its burst, then refills at its rate" {
    var bucket: Bucket = .init(2, 3);
    for (0..3) |_| try testing.expect(bucket.take(0));
    try testing.expect(!bucket.take(0));
    try testing.expect(bucket.take(second / 2));
    try testing.expect(!bucket.take(second / 2));
    try testing.expect(bucket.take(10 * second));
    try testing.expect(bucket.take(10 * second));
    try testing.expect(bucket.take(10 * second));
    try testing.expect(!bucket.take(10 * second));
}

test "a bucket never refills beyond its burst" {
    var bucket: Bucket = .init(100, 2);
    try testing.expect(bucket.take(0));
    try testing.expect(bucket.take(1000 * second));
    try testing.expect(bucket.take(1000 * second));
    try testing.expect(!bucket.take(1000 * second));
}

test "a time that arrives out of order neither mints tokens nor rewinds the clock" {
    var bucket: Bucket = .init(1, 1);
    try testing.expect(bucket.take(10 * second));
    try testing.expect(!bucket.take(5 * second));
    try testing.expect(!bucket.take(10 * second));
    try testing.expect(bucket.take(11 * second));
}

test "a disabled limit always allows" {
    var connection: Connection = .init(.{ .events = null, .messages = null, .subscriptions = null });
    for (0..10_000) |_| try testing.expect(connection.event(0));
}

test "authors are limited separately, and the same author across calls shares a budget" {
    var authors = try Authors.init(testing.allocator, testing.io, .{ .per_second = 1, .burst = 2 });
    defer authors.deinit(testing.allocator);
    const alice = [_]u8{1} ** 32;
    const bob = [_]u8{2} ** 32;
    try testing.expect(authors.take(&alice, 0));
    try testing.expect(authors.take(&alice, 0));
    try testing.expect(!authors.take(&alice, 0));
    const bob_slot = std.crypto.auth.siphash.SipHash64(2, 4).toInt(&bob, &authors.key) % authors.slots.len;
    const alice_slot = std.crypto.auth.siphash.SipHash64(2, 4).toInt(&alice, &authors.key) % authors.slots.len;
    if (bob_slot != alice_slot) try testing.expect(authors.take(&bob, 0));
}
