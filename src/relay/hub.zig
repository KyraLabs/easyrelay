//! Where an accepted event meets every subscription that wants it.
//!
//! A connection publishes on its own thread and the subscribers are on others,
//! so this is the one place in the relay where two connections touch. Two locks
//! make that safe, and they are always taken in this order: the hub's, then the
//! subscriber's. Nothing takes them the other way round, which is what keeps
//! the pair from deadlocking.
//!
//! Delivery is best-effort by design. A subscriber whose socket is dead is the
//! transport's problem to notice, not the publisher's to wait on; the publisher
//! has already been told its event was accepted, and blocking it on a slow
//! reader would let one client stall another. Per-connection backpressure and
//! the disconnect that goes with it are Phase 3.

const std = @import("std");
const nostr = @import("nostr");

const codec = @import("codec.zig");
const subscriptions = @import("subscriptions.zig");

const Event = nostr.event.Event;
const log = std.log.scoped(.relay);

/// How a delivered message reaches a connection. `send` is called from another
/// connection's thread, so the transport behind it must be safe to write to
/// concurrently — `websocket.zig` documents that its `Conn.write` is.
pub const Delivery = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, message: []const u8) void,

    pub fn send(self: Delivery, message: []const u8) void {
        self.sendFn(self.ptr, message);
    }
};

/// One connection as the rest of the relay sees it: what it is subscribed to,
/// and how to hand it bytes.
pub const Subscriber = struct {
    /// Guards `registry`, which this connection's own thread mutates on `REQ`
    /// and `CLOSE` while publishers read it.
    ///
    /// The connection also holds it across the whole of a `REQ` — opening the
    /// subscription, streaming the stored events, and sending `EOSE` — so that
    /// no live event can arrive in the middle of the stored phase.
    /// docs/protocol.md requires every stored event to precede `EOSE`.
    mutex: std.Io.Mutex = .init,
    registry: subscriptions.Registry,
    delivery: Delivery,
};

pub const Hub = struct {
    gpa: std.mem.Allocator,
    /// Locking goes through `Io` in Zig 0.16, so the hub keeps the one the
    /// relay was started with rather than taking it on every call.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    members: std.ArrayList(*Subscriber) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Hub {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Hub) void {
        self.members.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn join(self: *Hub, subscriber: *Subscriber) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.members.append(self.gpa, subscriber);
    }

    /// Tolerates a subscriber that never joined, because a connection that
    /// failed to start still runs its cleanup.
    pub fn leave(self: *Hub, subscriber: *Subscriber) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.members.items, 0..) |member, index| {
            if (member == subscriber) {
                _ = self.members.swapRemove(index);
                return;
            }
        }
    }

    pub fn count(self: *Hub) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.members.items.len;
    }

    /// Sends `event` to every open subscription whose filters match it,
    /// including the publisher's own: a client that subscribes and then
    /// publishes expects to see what it published.
    ///
    /// `arena` is the publisher's per-message arena, used to compose each
    /// message and released when its message is done.
    pub fn broadcast(self: *Hub, arena: std.mem.Allocator, event: *const Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.members.items) |member| {
            member.mutex.lockUncancelable(self.io);
            defer member.mutex.unlock(self.io);

            for (member.registry.items()) |subscription| {
                if (!matchesAny(subscription.filters, event)) continue;
                deliver(arena, member, subscription.id, event);
            }
        }
    }
};

fn matchesAny(filters: []const nostr.filter.Filter, event: *const Event) bool {
    for (filters) |filter| {
        if (filter.matches(event.*)) return true;
    }
    return false;
}

fn deliver(
    arena: std.mem.Allocator,
    member: *Subscriber,
    subscription_id: []const u8,
    event: *const Event,
) void {
    var message: std.Io.Writer.Allocating = .init(arena);
    defer message.deinit();

    codec.writeEvent(&message.writer, arena, subscription_id, event.*) catch |err| {
        // Not silently: an event that could not be composed is a delivery that
        // did not happen, and the operator is the only one who can see it.
        // Phase 3 gives this a metric alongside the structured logging.
        log.warn("dropping a delivery to subscription {s}: {t}", .{ subscription_id, err });
        return;
    };
    member.delivery.send(message.written());
}

const testing = std.testing;

/// Stands in for a connection: keeps what it was handed.
const Listener = struct {
    received: std.ArrayList([]u8) = .empty,

    fn delivery(self: *Listener) Delivery {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(ptr: *anyopaque, message: []const u8) void {
        const self: *Listener = @ptrCast(@alignCast(ptr));
        const copy = testing.allocator.dupe(u8, message) catch return;
        self.received.append(testing.allocator, copy) catch testing.allocator.free(copy);
    }

    fn deinit(self: *Listener) void {
        for (self.received.items) |message| testing.allocator.free(message);
        self.received.deinit(testing.allocator);
    }
};

fn testEvent(kind: u16) Event {
    return .{
        .id = [_]u8{0xab} ** 32,
        .pubkey = [_]u8{0xcd} ** 32,
        .created_at = 1_700_000_000,
        .kind = kind,
        .tags = &.{},
        .content = "broadcast",
        .sig = [_]u8{0} ** 64,
    };
}

test "an event reaches the subscriptions that match it and no others" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var connections = Hub.init(testing.allocator, threaded.io());
    defer connections.deinit();

    var wants_notes = Listener{};
    defer wants_notes.deinit();
    var wants_reactions = Listener{};
    defer wants_reactions.deinit();

    var notes: Subscriber = .{
        .registry = subscriptions.Registry.init(testing.allocator, .{}),
        .delivery = wants_notes.delivery(),
    };
    defer notes.registry.deinit();
    var reactions: Subscriber = .{
        .registry = subscriptions.Registry.init(testing.allocator, .{}),
        .delivery = wants_reactions.delivery(),
    };
    defer reactions.registry.deinit();

    try notes.registry.open("notes", &[_]nostr.filter.Filter{.{ .kinds = &.{1} }});
    try reactions.registry.open("reactions", &[_]nostr.filter.Filter{.{ .kinds = &.{7} }});
    try connections.join(&notes);
    try connections.join(&reactions);
    try testing.expectEqual(@as(usize, 2), connections.count());

    const event = testEvent(1);
    connections.broadcast(arena_state.allocator(), &event);

    try testing.expectEqual(@as(usize, 1), wants_notes.received.items.len);
    try testing.expectEqual(@as(usize, 0), wants_reactions.received.items.len);
    try testing.expect(std.mem.startsWith(u8, wants_notes.received.items[0], "[\"EVENT\",\"notes\","));
}

test "a subscriber that has left is not delivered to" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var connections = Hub.init(testing.allocator, threaded.io());
    defer connections.deinit();

    var listener = Listener{};
    defer listener.deinit();
    var member: Subscriber = .{
        .registry = subscriptions.Registry.init(testing.allocator, .{}),
        .delivery = listener.delivery(),
    };
    defer member.registry.deinit();
    try member.registry.open("everything", &[_]nostr.filter.Filter{.{}});

    try connections.join(&member);
    connections.leave(&member);
    // Leaving twice is what a connection that never finished starting does.
    connections.leave(&member);
    try testing.expectEqual(@as(usize, 0), connections.count());

    const event = testEvent(1);
    connections.broadcast(arena_state.allocator(), &event);
    try testing.expectEqual(@as(usize, 0), listener.received.items.len);
}
