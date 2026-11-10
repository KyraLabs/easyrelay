const std = @import("std");
const nostr = @import("nostr");

const codec = @import("codec.zig");
const hub = @import("hub.zig");
const subscriptions = @import("subscriptions.zig");
const validation = @import("validation.zig");
const write_queue = @import("writer.zig");
const kinds = @import("../storage/kind.zig");
const store = @import("../storage/store.zig");

const Event = nostr.event.Event;

pub const Responder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = std.Io.Writer.Error;

    pub const VTable = struct {
        begin: *const fn (ptr: *anyopaque) std.Io.Writer.Error!*std.Io.Writer,
        send: *const fn (ptr: *anyopaque) std.Io.Writer.Error!void,
    };

    pub fn begin(self: Responder) std.Io.Writer.Error!*std.Io.Writer {
        return self.vtable.begin(self.ptr);
    }

    pub fn send(self: Responder) std.Io.Writer.Error!void {
        return self.vtable.send(self.ptr);
    }
};

pub const Error = Responder.Error || error{OutOfMemory};

pub const Limits = struct {
    event: validation.Limits = .{},
    message: codec.Limits = .{},
    subscription: subscriptions.Limits = .{},
};

pub const Shared = struct {
    io: std.Io,
    store: store.Store,
    hub: *hub.Hub,
    /// When set, events are committed on the writer thread, which sends their `OK`.
    writer: ?*write_queue.Writer = null,
    limits: Limits = .{},
};

pub const Context = struct {
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    now: i64,
};

pub const Session = struct {
    shared: *const Shared,
    responder: Responder,
    subscriber: *hub.Subscriber,

    pub fn handle(self: *Session, context: Context, data: []const u8) Error!void {
        var diagnostics: codec.Diagnostics = .{};
        const message = codec.decode(
            context.arena,
            data,
            self.shared.limits.message,
            &diagnostics,
        ) catch |err| switch (err) {
            error.MalformedMessage, error.UnsupportedMessage => {
                if (diagnostics.subject) |subscription_id| {
                    self.subscriber.mutex.lockUncancelable(self.shared.io);
                    defer self.subscriber.mutex.unlock(self.shared.io);
                    _ = self.subscriber.registry.close(subscription_id);
                    return self.sendClosed(subscription_id, .invalid, diagnostics.message());
                }
                return self.sendNotice(diagnostics.message());
            },
            error.OutOfMemory => return self.sendNotice("the relay is out of memory"),
        };

        switch (message) {
            .event => |event| try self.publish(context, event, data.len),
            .req => |req| try self.subscribe(context, req),
            .close => |close| {
                self.subscriber.mutex.lockUncancelable(self.shared.io);
                defer self.subscriber.mutex.unlock(self.shared.io);
                _ = self.subscriber.registry.close(close.subscription_id);
            },
        }
    }

    fn publish(
        self: *Session,
        context: Context,
        event: Event,
        serialized_length: usize,
    ) Error!void {
        var diagnostics: validation.Diagnostics = .{};
        const validator = validation.Validator{
            .limits = self.shared.limits.event,
            .signer = context.signer,
        };
        validator.validate(
            context.arena,
            &event,
            serialized_length,
            context.now,
            &diagnostics,
        ) catch |err| switch (err) {
            error.Invalid => return self.sendOk(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .invalid,
                .reason = diagnostics.message(),
            }),
            error.OutOfMemory => return self.sendOk(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .internal,
                .reason = "the relay ran out of memory validating this event",
            }),
        };

        if (kinds.classify(event.kind) == .ephemeral) {
            self.shared.hub.broadcast(context.arena, &event);
            return self.sendOk(.{ .event_id = event.id, .accepted = true });
        }

        if (self.shared.writer) |queue| {
            const reply: write_queue.Reply = .{ .subscriber = self.subscriber, .generation = self.subscriber.generation };
            queue.submit(&event, reply) catch |err| return self.sendOk(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = switch (err) {
                    error.QueueFull => .rate_limited,
                    error.OutOfMemory => .internal,
                },
                .reason = switch (err) {
                    error.QueueFull => "the write queue is full",
                    error.OutOfMemory => "the relay ran out of memory queueing this event",
                },
            });
            return;
        }

        const result = self.shared.store.put(&event) catch |err| return self.sendOk(write_queue.failure(event.id, err));
        if (result == .stored) self.shared.hub.broadcast(context.arena, &event);
        return self.sendOk(write_queue.ok(event.id, result));
    }

    fn subscribe(self: *Session, context: Context, req: codec.ClientMessage.Req) Error!void {
        self.subscriber.mutex.lockUncancelable(self.shared.io);
        defer self.subscriber.mutex.unlock(self.shared.io);

        self.subscriber.registry.open(req.subscription_id, req.filters) catch |err| switch (err) {
            error.TooMany => return self.sendClosed(
                req.subscription_id,
                .blocked,
                "this connection already holds as many subscriptions as it may",
            ),
            error.OutOfMemory => {
                _ = self.subscriber.registry.close(req.subscription_id);
                return self.sendClosed(
                    req.subscription_id,
                    .internal,
                    "the relay ran out of memory opening this subscription",
                );
            },
        };

        var sink: EventSink = .{
            .session = self,
            .subscription_id = req.subscription_id,
        };
        const bounded = subscriptions.resolveLimits(context.arena, req.filters, self.shared.limits.subscription) catch {
            _ = self.subscriber.registry.close(req.subscription_id);
            return self.sendClosed(
                req.subscription_id,
                .internal,
                "the relay ran out of memory opening this subscription",
            );
        };

        self.shared.store.query(bounded, sink.sink()) catch |err| switch (err) {
            error.Abort => return sink.failure orelse error.WriteFailed,
            error.OutOfMemory, error.Backend => {
                _ = self.subscriber.registry.close(req.subscription_id);
                return self.sendClosed(
                    req.subscription_id,
                    .internal,
                    "the store could not answer this subscription",
                );
            },
        };

        try self.sendEose(req.subscription_id);
    }

    fn sendEvent(self: *Session, subscription_id: []const u8, event: Event) Error!void {
        const writer = try self.responder.begin();
        try codec.writeEvent(writer, subscription_id, event);
        try self.responder.send();
    }

    fn sendEose(self: *Session, subscription_id: []const u8) Error!void {
        const writer = try self.responder.begin();
        try codec.writeEose(writer, subscription_id);
        try self.responder.send();
    }

    fn sendClosed(
        self: *Session,
        subscription_id: []const u8,
        prefix: codec.Prefix,
        reason: []const u8,
    ) Error!void {
        const writer = try self.responder.begin();
        try codec.writeClosed(writer, subscription_id, prefix, reason);
        try self.responder.send();
    }

    fn sendOk(self: *Session, ok: codec.Ok) Error!void {
        const writer = try self.responder.begin();
        try codec.writeOk(writer, ok);
        try self.responder.send();
    }

    fn sendNotice(self: *Session, message: []const u8) Error!void {
        const writer = try self.responder.begin();
        try codec.writeNotice(writer, message);
        try self.responder.send();
    }
};

const EventSink = struct {
    session: *Session,
    subscription_id: []const u8,
    failure: ?Error = null,

    fn sink(self: *EventSink) store.Sink {
        return .{ .ptr = self, .emitFn = emit };
    }

    fn emit(ptr: *anyopaque, event: *const Event) store.Sink.Abort!void {
        const self: *EventSink = @ptrCast(@alignCast(ptr));
        self.session.sendEvent(self.subscription_id, event.*) catch |err| {
            self.failure = err;
            return error.Abort;
        };
    }
};

const testing = std.testing;
const memory = @import("../storage/memory.zig");

const test_now: i64 = 1_700_000_000;

const Recorder = struct {
    gpa: std.mem.Allocator,
    current: std.Io.Writer.Allocating,
    messages: std.ArrayList([]u8),

    fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa, .current = .init(gpa), .messages = .empty };
    }

    fn deinit(self: *Recorder) void {
        for (self.messages.items) |message| self.gpa.free(message);
        self.messages.deinit(self.gpa);
        self.current.deinit();
    }

    fn responder(self: *Recorder) Responder {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Responder.VTable = .{ .begin = begin, .send = send };

    fn begin(ptr: *anyopaque) Responder.Error!*std.Io.Writer {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.current.writer.end = 0;
        return &self.current.writer;
    }

    fn send(ptr: *anyopaque) Responder.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const message = self.gpa.dupe(u8, self.current.written()) catch return error.WriteFailed;
        errdefer self.gpa.free(message);
        self.messages.append(self.gpa, message) catch return error.WriteFailed;
    }

    fn clear(self: *Recorder) void {
        for (self.messages.items) |message| self.gpa.free(message);
        self.messages.clearRetainingCapacity();
    }

    fn only(self: *Recorder) []const u8 {
        std.debug.assert(self.messages.items.len == 1);
        return self.messages.items[0];
    }
};

const Harness = struct {
    threaded: std.Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    signer: nostr.keys.Signer,
    backing: memory.Memory,
    recorder: Recorder,
    delivered: std.ArrayList([]u8),
    limits: Limits,
    override_store: ?store.Store = null,
    connections: hub.Hub = undefined,
    subscriber: hub.Subscriber = undefined,
    shared: Shared = undefined,
    session: Session = undefined,

    fn init(limits: Limits) Harness {
        return .{
            .threaded = .init(testing.allocator, .{}),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .signer = nostr.keys.Signer.init(),
            .backing = memory.Memory.init(testing.allocator, testing.io),
            .recorder = Recorder.init(testing.allocator),
            .delivered = .empty,
            .limits = limits,
        };
    }

    fn start(self: *Harness) !void {
        const io = self.threaded.io();
        self.connections = hub.Hub.init(testing.allocator, io);
        self.subscriber = .{
            .registry = subscriptions.Registry.init(testing.allocator, self.limits.subscription),
            .delivery = .{ .ptr = self, .sendFn = record },
        };
        try self.connections.join(&self.subscriber);
        self.shared = .{
            .io = io,
            .store = self.override_store orelse self.backing.store(),
            .hub = &self.connections,
            .limits = self.limits,
        };
        self.session = .{
            .shared = &self.shared,
            .responder = self.recorder.responder(),
            .subscriber = &self.subscriber,
        };
    }

    fn record(ptr: *anyopaque, message: []const u8) void {
        const self: *Harness = @ptrCast(@alignCast(ptr));
        const copy = testing.allocator.dupe(u8, message) catch return;
        self.delivered.append(testing.allocator, copy) catch testing.allocator.free(copy);
    }

    fn deinit(self: *Harness) void {
        for (self.delivered.items) |message| testing.allocator.free(message);
        self.delivered.deinit(testing.allocator);
        self.subscriber.registry.deinit();
        self.connections.deinit();
        self.recorder.deinit();
        self.backing.deinit();
        self.signer.deinit();
        self.arena_state.deinit();
        self.threaded.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn handle(self: *Harness, data: []const u8) !void {
        return self.session.handle(.{
            .arena = self.arena(),
            .signer = self.signer,
            .now = test_now,
        }, data);
    }

    fn signedEvent(self: *Harness, content: []const u8) !Event {
        return self.signedEventAt(test_now, content);
    }

    fn signedEventAt(self: *Harness, created_at: i64, content: []const u8) !Event {
        const keypair = try self.signer.keyPairFromSecretKey([_]u8{3} ** 32);
        return nostr.event.create(self.arena(), self.signer, keypair, created_at, 1, &.{}, content, null);
    }

    fn eventMessage(self: *Harness, event: Event) ![]u8 {
        return nostr.message.encodeEvent(self.arena(), event);
    }
};

test "a well-formed event is stored and answered with OK true" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    const event = try harness.signedEvent("hello");
    try harness.handle(try harness.eventMessage(event));

    const id = std.fmt.bytesToHex(event.id, .lower);
    const expected = try std.fmt.allocPrint(harness.arena(), "[\"OK\",\"{s}\",true,\"\"]", .{id});
    try testing.expectEqualStrings(expected, harness.recorder.only());
}

test "the same event twice is answered with duplicate, and still with true" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    const event = try harness.signedEvent("hello");
    const wire = try harness.eventMessage(event);
    try harness.handle(wire);
    try harness.handle(wire);

    try testing.expectEqual(@as(usize, 2), harness.recorder.messages.items.len);
    const second = harness.recorder.messages.items[1];
    try testing.expect(std.mem.indexOf(u8, second, ",true,\"duplicate: already stored\"]") != null);
}

test "an event whose signature does not verify is answered with invalid" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    var event = try harness.signedEvent("hello");
    event.sig[0] ^= 0xff;
    try harness.handle(try harness.eventMessage(event));

    const answer = harness.recorder.only();
    try testing.expect(std.mem.indexOf(u8, answer, ",false,\"invalid: signature does not verify") != null);
}

test "an event over the size limit is refused with the limit in the reason" {
    var harness = Harness.init(.{ .event = .{ .max_event_size = 32 } });
    try harness.start();
    defer harness.deinit();

    const event = try harness.signedEvent("hello");
    try harness.handle(try harness.eventMessage(event));

    const answer = harness.recorder.only();
    try testing.expect(std.mem.indexOf(u8, answer, ",false,\"invalid: event is ") != null);
    try testing.expect(std.mem.indexOf(u8, answer, "over the 32 byte limit") != null);
}

test "a rejected event is not stored" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    var event = try harness.signedEvent("hello");
    event.sig[0] ^= 0xff;
    const wire = try harness.eventMessage(event);
    try harness.handle(wire);

    event.sig[0] ^= 0xff;
    try harness.handle(try harness.eventMessage(event));

    const second = harness.recorder.messages.items[1];
    try testing.expect(std.mem.indexOf(u8, second, ",true,\"\"]") != null);
}

test "input that is not a message is answered with NOTICE" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("not a message");
    try testing.expectEqualStrings("[\"NOTICE\",\"message is not valid JSON\"]", harness.recorder.only());
}

test "a message type this relay does not implement is answered with NOTICE" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"COUNT\",\"sub\",{}]");
    try testing.expect(std.mem.indexOf(u8, harness.recorder.only(), "does not support COUNT") != null);
}

test "a REQ answers with the stored events, newest first, and then EOSE" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    const older = try harness.signedEvent("older");
    var newer = try harness.signedEventAt(test_now + 10, "newer");
    try harness.handle(try harness.eventMessage(older));
    try harness.handle(try harness.eventMessage(newer));
    harness.recorder.clear();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");

    const sent = harness.recorder.messages.items;
    try testing.expectEqual(@as(usize, 3), sent.len);
    try testing.expect(std.mem.indexOf(u8, sent[0], "newer") != null);
    try testing.expect(std.mem.indexOf(u8, sent[1], "older") != null);
    try testing.expectEqualStrings("[\"EOSE\",\"sub-1\"]", sent[2]);
    newer = undefined;
}

test "a REQ that matches nothing still ends with EOSE" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[9999]}]");
    try testing.expectEqualStrings("[\"EOSE\",\"sub-1\"]", harness.recorder.only());
}

test "a REQ reusing an open id replaces that subscription" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[1]}]");
    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[7]}]");

    try testing.expectEqual(@as(usize, 1), harness.subscriber.registry.count());
    const open_subscription = harness.subscriber.registry.find("sub-1").?;
    try testing.expectEqual(@as(u16, 7), open_subscription.filters[0].kinds.?[0]);
}

test "CLOSE ends the subscription and says nothing" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    harness.recorder.clear();

    try harness.handle("[\"CLOSE\",\"sub-1\"]");
    try testing.expectEqual(@as(usize, 0), harness.subscriber.registry.count());
    try testing.expectEqual(@as(usize, 0), harness.recorder.messages.items.len);
}

test "closing a subscription that was never open is not an error" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"CLOSE\",\"never-opened\"]");
    try testing.expectEqual(@as(usize, 0), harness.recorder.messages.items.len);
}

test "one subscription too many is refused with CLOSED and blocked" {
    var harness = Harness.init(.{ .subscription = .{ .max_subscriptions = 1 } });
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    harness.recorder.clear();
    try harness.handle("[\"REQ\",\"sub-2\",{}]");

    const answer = harness.recorder.only();
    try testing.expect(std.mem.startsWith(u8, answer, "[\"CLOSED\",\"sub-2\",\"blocked:"));
    try testing.expectEqual(@as(usize, 1), harness.subscriber.registry.count());
}

test "a REQ refused by the codec is answered with CLOSED naming the subscription" {
    var harness = Harness.init(.{ .message = .{ .max_filters = 1 } });
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{},{}]");

    const answer = harness.recorder.only();
    try testing.expect(std.mem.startsWith(u8, answer, "[\"CLOSED\",\"sub-1\",\"invalid:"));
    try testing.expect(std.mem.indexOf(u8, answer, "over the limit of 1") != null);
}

test "an invalid REQ replacing an open subscription closes it" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    harness.recorder.clear();
    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[-1]}]");
    try testing.expect(std.mem.startsWith(u8, harness.recorder.only(), "[\"CLOSED\",\"sub-1\",\"invalid:"));
    try testing.expectEqual(@as(usize, 0), harness.subscriber.registry.count());

    try harness.handle(try harness.eventMessage(try harness.signedEvent("after CLOSED")));
    try testing.expectEqual(@as(usize, 0), harness.delivered.items.len);
}

test "a replacement that runs out of memory closes the subscription it announces closed" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    harness.recorder.clear();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    harness.subscriber.registry.gpa = failing.allocator();
    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[7]}]");
    harness.subscriber.registry.gpa = testing.allocator;

    try testing.expect(std.mem.startsWith(u8, harness.recorder.only(), "[\"CLOSED\",\"sub-1\",\"error:"));
    try testing.expectEqual(@as(usize, 0), harness.subscriber.registry.count());
}

test "a filter in a REQ decides what the subscription is answered with" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle(try harness.eventMessage(try harness.signedEvent("kept")));
    harness.recorder.clear();

    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[1]},{\"kinds\":[7]}]");
    const sent = harness.recorder.messages.items;
    try testing.expectEqual(@as(usize, 2), sent.len);
    try testing.expect(std.mem.indexOf(u8, sent[0], "kept") != null);
    try testing.expectEqualStrings("[\"EOSE\",\"sub-1\"]", sent[1]);
}

test "an accepted event reaches an open subscription that matches it" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[1]}]");
    try harness.handle(try harness.eventMessage(try harness.signedEvent("live")));

    try testing.expectEqual(@as(usize, 1), harness.delivered.items.len);
    const delivered = harness.delivered.items[0];
    try testing.expect(std.mem.startsWith(u8, delivered, "[\"EVENT\",\"sub-1\","));
    try testing.expect(std.mem.indexOf(u8, delivered, "live") != null);
}

test "an accepted event reaches nothing when no filter matches it" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{\"kinds\":[7]}]");
    try harness.handle(try harness.eventMessage(try harness.signedEvent("live")));

    try testing.expectEqual(@as(usize, 0), harness.delivered.items.len);
}

test "an event already stored is not delivered a second time" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    const wire = try harness.eventMessage(try harness.signedEvent("once"));
    try harness.handle(wire);
    try harness.handle(wire);

    try testing.expectEqual(@as(usize, 1), harness.delivered.items.len);
}

test "a closed subscription stops receiving" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"sub-1\",{}]");
    try harness.handle("[\"CLOSE\",\"sub-1\"]");
    try harness.handle(try harness.eventMessage(try harness.signedEvent("after")));

    try testing.expectEqual(@as(usize, 0), harness.delivered.items.len);
}

const FailingStore = struct {
    put_error: ?store.Error = null,
    query_error: ?store.Error = null,

    const vtable: store.Store.VTable = .{ .put = put, .putBatch = putBatch, .query = query };

    fn interface(self: *FailingStore) store.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn put(ptr: *anyopaque, event: *const Event) store.Error!store.PutResult {
        const self: *FailingStore = @ptrCast(@alignCast(ptr));
        _ = event;
        if (self.put_error) |failure| return failure;
        return .stored;
    }

    fn putBatch(ptr: *anyopaque, events: []const Event, results: []store.PutResult) store.Error!void {
        for (events, results) |*event, *result| result.* = try put(ptr, event);
    }

    fn query(ptr: *anyopaque, filters: []const nostr.filter.Filter, sink: store.Sink) store.QueryError!void {
        const self: *FailingStore = @ptrCast(@alignCast(ptr));
        _ = .{ filters, sink };
        if (self.query_error) |failure| return failure;
    }
};

test "an event the store cannot accept is answered with error:" {
    for ([_]store.Error{ error.Backend, error.OutOfMemory }) |failure| {
        var failing: FailingStore = .{ .put_error = failure };
        var harness = Harness.init(.{});
        harness.override_store = failing.interface();
        try harness.start();
        defer harness.deinit();

        try harness.handle(try harness.eventMessage(try harness.signedEvent("refused")));

        const answer = harness.recorder.only();
        try testing.expect(std.mem.indexOf(u8, answer, ",false,\"error:") != null);
        try testing.expectEqual(@as(usize, 0), harness.delivered.items.len);
    }
}

test "a subscription the store cannot answer is closed, not left open" {
    for ([_]store.Error{ error.Backend, error.OutOfMemory }) |failure| {
        var failing: FailingStore = .{ .query_error = failure };
        var harness = Harness.init(.{});
        harness.override_store = failing.interface();
        try harness.start();
        defer harness.deinit();

        try harness.handle("[\"REQ\",\"sub-1\",{}]");

        const answer = harness.recorder.only();
        try testing.expect(std.mem.startsWith(u8, answer, "[\"CLOSED\",\"sub-1\",\"error:"));
        try testing.expectEqual(@as(usize, 0), harness.subscriber.registry.count());
    }
}

test "an event the write queue cannot take is refused with rate-limited" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    var queue = try write_queue.Writer.init(testing.allocator, harness.shared.io, harness.shared.store, &harness.connections, 1);
    defer {
        queue.start() catch {};
        queue.stop();
        queue.deinit();
    }
    harness.shared.writer = &queue;

    try harness.handle(try harness.eventMessage(try harness.signedEvent("queued")));
    try testing.expectEqual(@as(usize, 0), harness.recorder.messages.items.len);

    try harness.handle(try harness.eventMessage(try harness.signedEvent("refused")));
    try testing.expect(std.mem.indexOf(u8, harness.recorder.only(), ",false,\"rate-limited: the write queue is full\"]") != null);
}
