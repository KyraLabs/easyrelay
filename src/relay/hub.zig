const std = @import("std");
const nostr = @import("nostr");

const codec = @import("codec.zig");
const subscriptions = @import("subscriptions.zig");

const Event = nostr.event.Event;
const log = std.log.scoped(.relay);

pub const Delivery = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, message: []const u8) void,

    pub fn send(self: Delivery, message: []const u8) void {
        self.sendFn(self.ptr, message);
    }
};

pub const Subscriber = struct {
    /// Lock order: hub, then subscriber.
    mutex: std.Io.Mutex = .init,
    registry: subscriptions.Registry,
    delivery: Delivery,
};

pub const Hub = struct {
    gpa: std.mem.Allocator,
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

    pub fn broadcast(self: *Hub, arena: std.mem.Allocator, event: *const Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var serialized: ?[]const u8 = null;

        for (self.members.items) |member| {
            member.mutex.lockUncancelable(self.io);
            defer member.mutex.unlock(self.io);

            for (member.registry.items()) |subscription| {
                if (!matchesAny(subscription.filters, event)) continue;

                const body = serialized orelse body: {
                    const rendered = render(arena, event) catch |err| {
                        log.warn(
                            "dropping the fan-out of event {s}: {t}",
                            .{ std.fmt.bytesToHex(event.id, .lower), err },
                        );
                        return;
                    };
                    serialized = rendered;
                    break :body rendered;
                };
                deliver(arena, member, subscription.id, body);
            }
        }
    }
};

fn render(arena: std.mem.Allocator, event: *const Event) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    codec.writeEventJson(&out.writer, event.*) catch return error.OutOfMemory;
    return out.written();
}

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
    serialized_event: []const u8,
) void {
    var message: std.Io.Writer.Allocating = .init(arena);
    defer message.deinit();

    codec.writeEventEnvelope(&message.writer, subscription_id, serialized_event) catch |err| {
        log.warn("dropping a delivery to subscription {s}: {t}", .{ subscription_id, err });
        return;
    };
    member.delivery.send(message.written());
}

const testing = std.testing;

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
    connections.leave(&member);
    try testing.expectEqual(@as(usize, 0), connections.count());

    const event = testEvent(1);
    connections.broadcast(arena_state.allocator(), &event);
    try testing.expectEqual(@as(usize, 0), listener.received.items.len);
}

test "a delivered event with control bytes is valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var connections = Hub.init(testing.allocator, testing.io);
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

    var event = testEvent(1);
    event.content = "control\x01byte";
    connections.broadcast(arena_state.allocator(), &event);

    try testing.expectEqual(@as(usize, 1), listener.received.items.len);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), listener.received.items[0], .{});
    try testing.expectEqualStrings("control\x01byte", parsed.array.items[2].object.get("content").?.string);
}
