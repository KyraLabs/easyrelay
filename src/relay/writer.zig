const std = @import("std");
const nostr = @import("nostr");

const codec = @import("codec.zig");
const hub = @import("hub.zig");
const store = @import("../storage/store.zig");

const Event = nostr.event.Event;
const PutResult = store.PutResult;
const log = std.log.scoped(.writer);

pub const max_batch = 1024;

pub const Reply = struct {
    subscriber: *hub.Subscriber,
    generation: u64,
};

pub const SubmitError = error{ QueueFull, OutOfMemory };

pub fn ok(event_id: [32]u8, result: PutResult) codec.Ok {
    return switch (result) {
        .stored => .{ .event_id = event_id, .accepted = true },
        .duplicate => .{ .event_id = event_id, .accepted = true, .prefix = .duplicate, .reason = "already stored" },
        .outdated => .{ .event_id = event_id, .accepted = true, .prefix = .duplicate, .reason = "a newer version is stored" },
    };
}

pub fn failure(event_id: [32]u8, err: store.Error) codec.Ok {
    return .{
        .event_id = event_id,
        .accepted = false,
        .prefix = .internal,
        .reason = switch (err) {
            error.OutOfMemory => "the relay ran out of memory storing this event",
            error.Backend => "the store could not accept this event",
        },
    };
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    event: Event,
    reply: Reply,
};

/// The only thread that writes to the store. Events arrive through a bounded queue and are
/// committed in batches; the `OK` and the fan-out follow the commit.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: store.Store,
    hub: *hub.Hub,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    queue: []*Job,
    head: usize = 0,
    len: usize = 0,
    stopping: bool = false,
    thread: ?std.Thread = null,
    batch_events: []Event,
    batch_results: []PutResult,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, backend: store.Store, connections: *hub.Hub, depth: usize) !Writer {
        std.debug.assert(depth > 0);
        const queue = try gpa.alloc(*Job, depth);
        errdefer gpa.free(queue);
        const batch_events = try gpa.alloc(Event, max_batch);
        errdefer gpa.free(batch_events);
        const batch_results = try gpa.alloc(PutResult, max_batch);
        return .{
            .gpa = gpa,
            .io = io,
            .store = backend,
            .hub = connections,
            .queue = queue,
            .batch_events = batch_events,
            .batch_results = batch_results,
        };
    }

    pub fn deinit(self: *Writer) void {
        std.debug.assert(self.thread == null and self.len == 0);
        self.gpa.free(self.batch_results);
        self.gpa.free(self.batch_events);
        self.gpa.free(self.queue);
        self.* = undefined;
    }

    pub fn start(self: *Writer) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Commits everything already queued, then joins the thread.
    pub fn stop(self: *Writer) void {
        const thread = self.thread orelse return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stopping = true;
        }
        self.wake.broadcast(self.io);
        thread.join();
        self.thread = null;
    }

    pub fn submit(self: *Writer, event: *const Event, reply: Reply) SubmitError!void {
        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);
        job.arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer job.arena.deinit();
        job.event = try copyEvent(job.arena.allocator(), event);
        job.reply = reply;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.len == self.queue.len) return error.QueueFull;
        self.queue[(self.head + self.len) % self.queue.len] = job;
        self.len += 1;
        self.wake.signal(self.io);
    }

    fn run(self: *Writer) void {
        const jobs = self.gpa.alloc(*Job, max_batch) catch @panic("writer could not allocate its batch");
        defer self.gpa.free(jobs);
        while (true) {
            const taken = self.take(jobs);
            if (taken == 0) return;
            self.commit(jobs[0..taken]);
        }
    }

    fn take(self: *Writer, jobs: []*Job) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.len == 0 and !self.stopping) self.wake.waitUncancelable(self.io, &self.mutex);
        const count = @min(self.len, jobs.len);
        for (jobs[0..count]) |*job| {
            job.* = self.queue[self.head];
            self.head = (self.head + 1) % self.queue.len;
        }
        self.len -= count;
        return count;
    }

    fn commit(self: *Writer, jobs: []*Job) void {
        const events = self.batch_events[0..jobs.len];
        const results = self.batch_results[0..jobs.len];
        for (jobs, events) |job, *event| event.* = job.event;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const outcome = self.store.putBatch(events, results);
        for (jobs, results) |job, result| {
            defer {
                job.arena.deinit();
                self.gpa.destroy(job);
            }
            _ = arena_state.reset(.retain_capacity);
            const answer = if (outcome) |_| answer: {
                if (result == .stored) self.hub.broadcast(arena, &job.event);
                break :answer ok(job.event.id, result);
            } else |err| failure(job.event.id, err);
            self.send(arena, job.reply, answer);
        }
    }

    fn send(self: *Writer, arena: std.mem.Allocator, reply: Reply, answer: codec.Ok) void {
        var message: std.Io.Writer.Allocating = .init(arena);
        codec.writeOk(&message.writer, answer) catch |err| {
            log.warn("dropping an OK: {t}", .{err});
            return;
        };
        self.hub.reply(reply.subscriber, reply.generation, message.written());
    }
};

fn copyEvent(arena: std.mem.Allocator, event: *const Event) error{OutOfMemory}!Event {
    const tags = try arena.alloc(nostr.event.Tag, event.tags.len);
    for (event.tags, tags) |source, *target| {
        const fields = try arena.alloc([]const u8, source.len);
        for (source, fields) |field, *copy| copy.* = try arena.dupe(u8, field);
        target.* = fields;
    }
    var owned = event.*;
    owned.tags = tags;
    owned.content = try arena.dupe(u8, event.content);
    return owned;
}

const testing = std.testing;
const memory = @import("../storage/memory.zig");
const subscriptions = @import("subscriptions.zig");

const Inbox = struct {
    mutex: std.Io.Mutex = .init,
    received: std.ArrayList([]u8) = .empty,

    fn delivery(self: *Inbox) hub.Delivery {
        return .{ .ptr = self, .sendFn = deliver };
    }

    fn deliver(ptr: *anyopaque, message: []const u8) void {
        const self: *Inbox = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        const copy = testing.allocator.dupe(u8, message) catch return;
        self.received.append(testing.allocator, copy) catch testing.allocator.free(copy);
    }

    fn deinit(self: *Inbox) void {
        for (self.received.items) |message| testing.allocator.free(message);
        self.received.deinit(testing.allocator);
    }
};

fn testEvent(id_byte: u8, kind: u16) Event {
    return .{
        .id = [_]u8{id_byte} ** 32,
        .pubkey = [_]u8{0xab} ** 32,
        .created_at = 1_700_000_000 + @as(i64, id_byte),
        .kind = kind,
        .tags = &.{&.{ "t", "copied" }},
        .content = "queued",
        .sig = [_]u8{0} ** 64,
    };
}

test "queued events are stored, answered and fanned out after the commit" {
    var backing = memory.Memory.init(testing.allocator, testing.io);
    defer backing.deinit();
    var connections = hub.Hub.init(testing.allocator, testing.io);
    defer connections.deinit();

    var inbox: Inbox = .{};
    defer inbox.deinit();
    var subscriber: hub.Subscriber = .{
        .registry = subscriptions.Registry.init(testing.allocator, .{}),
        .delivery = inbox.delivery(),
    };
    defer subscriber.registry.deinit();
    try subscriber.registry.open("all", &.{.{}});
    try connections.join(&subscriber);
    defer connections.leave(&subscriber);

    var writer = try Writer.init(testing.allocator, testing.io, backing.store(), &connections, 8);
    defer writer.deinit();
    try writer.start();

    const reply: Reply = .{ .subscriber = &subscriber, .generation = subscriber.generation };
    {
        var first = testEvent(1, 1);
        try writer.submit(&first, reply);
        first.content = "overwritten after submit";
    }
    const duplicate = testEvent(1, 1);
    try writer.submit(&duplicate, reply);
    writer.stop();

    try testing.expectEqual(@as(usize, 3), inbox.received.items.len);
    try testing.expect(std.mem.startsWith(u8, inbox.received.items[0], "[\"EVENT\",\"all\","));
    try testing.expect(std.mem.indexOf(u8, inbox.received.items[0], "\"queued\"") != null);
    try testing.expect(std.mem.endsWith(u8, inbox.received.items[1], ",true,\"\"]"));
    try testing.expect(std.mem.endsWith(u8, inbox.received.items[2], ",true,\"duplicate: already stored\"]"));
}

test "a full queue refuses the event" {
    var backing = memory.Memory.init(testing.allocator, testing.io);
    defer backing.deinit();
    var connections = hub.Hub.init(testing.allocator, testing.io);
    defer connections.deinit();
    var inbox: Inbox = .{};
    defer inbox.deinit();
    var subscriber: hub.Subscriber = .{
        .registry = subscriptions.Registry.init(testing.allocator, .{}),
        .delivery = inbox.delivery(),
    };
    defer subscriber.registry.deinit();

    var writer = try Writer.init(testing.allocator, testing.io, backing.store(), &connections, 2);
    defer writer.deinit();

    const reply: Reply = .{ .subscriber = &subscriber, .generation = 0 };
    for ([_]u8{ 1, 2 }) |id_byte| {
        const event = testEvent(id_byte, 1);
        try writer.submit(&event, reply);
    }
    const third = testEvent(3, 1);
    try testing.expectError(error.QueueFull, writer.submit(&third, reply));

    try writer.start();
    writer.stop();
    var collector_count: usize = 0;
    var counter = Counter{ .count = &collector_count };
    try backing.store().query(&.{.{}}, counter.sink());
    try testing.expectEqual(@as(usize, 2), collector_count);
}

const Counter = struct {
    count: *usize,

    fn sink(self: *Counter) store.Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) store.Sink.Abort!void {
        _ = event;
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.count.* += 1;
    }
};
