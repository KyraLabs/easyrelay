const std = @import("std");
const nostr = @import("nostr");

const codec = @import("codec.zig");
const hub = @import("hub.zig");
const rate = @import("rate.zig");
const policy = @import("policy.zig");
const metrics = @import("metrics.zig");
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

pub const Error = Responder.Error || error{
    OutOfMemory,
    RateLimited,
};

pub const Limits = struct {
    event: validation.Limits = .{},
    message: codec.Limits = .{},
    subscription: subscriptions.Limits = .{},
};

pub const Shared = struct {
    io: std.Io,
    store: store.Store,
    hub: *hub.Hub,
    writer: ?*write_queue.Writer = null,
    limits: Limits = .{},
    /// Charged only after the signature verifies.
    authors: ?*rate.Authors = null,
    policy: policy.Policy = .{},
    metrics: ?*metrics.Metrics = null,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    signer: nostr.keys.Signer,
    now: i64,
    clock_ns: i96 = 0,
};

pub const auth_kind: u16 = 22242;
pub const auth_window_s: i64 = 600;

pub const Peer = struct {
    rates: ?rate.Connection = null,
    challenge: [32]u8,
    challenged: bool = false,
    host_buffer: [256]u8 = undefined,
    host_len: usize = 0,
    authenticated: [max_authenticated][32]u8 = undefined,
    authenticated_len: usize = 0,

    pub const max_authenticated = 8;

    pub fn init(io: std.Io, rates: ?rate.Limits, host_header: ?[]const u8) Peer {
        var nonce: [16]u8 = undefined;
        io.randomSecure(&nonce) catch io.random(&nonce);
        var peer: Peer = .{
            .rates = if (rates) |limits| .init(limits) else null,
            .challenge = std.fmt.bytesToHex(nonce, .lower),
        };
        if (host_header) |text| if (text.len <= peer.host_buffer.len) {
            @memcpy(peer.host_buffer[0..text.len], text);
            peer.host_len = text.len;
        };
        return peer;
    }

    pub fn host(self: *const Peer) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    pub fn isAuthenticated(self: *const Peer) bool {
        return self.authenticated_len != 0;
    }

    pub fn isAuthenticatedAs(self: *const Peer, pubkey: *const [32]u8) bool {
        for (self.authenticated[0..self.authenticated_len]) |*known| {
            if (std.mem.eql(u8, known, pubkey)) return true;
        }
        return false;
    }

    fn remember(self: *Peer, pubkey: *const [32]u8) void {
        if (self.isAuthenticatedAs(pubkey)) return;
        if (self.authenticated_len == max_authenticated) {
            std.mem.copyForwards([32]u8, self.authenticated[0 .. max_authenticated - 1], self.authenticated[1..]);
            self.authenticated_len -= 1;
        }
        self.authenticated[self.authenticated_len] = pubkey.*;
        self.authenticated_len += 1;
    }
};

pub const Session = struct {
    shared: *const Shared,
    responder: Responder,
    subscriber: *hub.Subscriber,
    peer: ?*Peer = null,

    pub fn greet(self: *Session) Error!void {
        const policy_requires = self.shared.policy.auth_required_for_read or self.shared.policy.auth_required_for_write;
        if (policy_requires) try self.challenge();
    }

    pub fn handle(self: *Session, context: Context, data: []const u8) Error!void {
        if (self.peer) |peer| if (peer.rates) |*rates| if (!rates.message(context.clock_ns)) return error.RateLimited;

        var diagnostics: codec.Diagnostics = .{};
        const message = codec.decode(
            context.arena,
            data,
            self.shared.limits.message,
            &diagnostics,
        ) catch |err| switch (err) {
            error.MalformedMessage, error.UnsupportedMessage => {
                if (diagnostics.subject) |subscription_id| {
                    self.closeSubscription(subscription_id);
                    return self.sendClosed(subscription_id, .invalid, diagnostics.message());
                }
                return self.sendNotice(diagnostics.message());
            },
            error.OutOfMemory => return self.sendNotice("the relay is out of memory"),
        };

        switch (message) {
            .event => |event| try self.publish(context, event, data.len),
            .auth => |event| try self.authenticate(context, event, data.len),
            .req => |req| try self.subscribe(context, req),
            .close => |close| self.closeSubscription(close.subscription_id),
        }
    }

    fn publish(
        self: *Session,
        context: Context,
        event: Event,
        serialized_length: usize,
    ) Error!void {
        if (self.peer) |peer| if (peer.rates) |*rates| if (!rates.event(context.clock_ns)) return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .rate_limited,
            .reason = "this connection is publishing too fast",
        });
        var diagnostics: validation.Diagnostics = .{};
        const validator = validation.Validator{
            .limits = self.shared.limits.event,
            .signer = context.signer,
        };
        const validation_started = std.Io.Timestamp.now(self.shared.io, .awake);
        const validated = validator.validate(
            context.arena,
            &event,
            serialized_length,
            context.now,
            &diagnostics,
        );
        if (self.shared.metrics) |counters| counters.validation.observe(elapsed(self.shared.io, validation_started));
        validated catch |err| switch (err) {
            error.Invalid => return self.answer(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .invalid,
                .reason = diagnostics.message(),
            }),
            error.OutOfMemory => return self.answer(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .internal,
                .reason = "the relay ran out of memory validating this event",
            }),
        };
        const expires = kinds.expiration(&event) catch return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .invalid,
            .reason = "the expiration tag is not a unix timestamp",
        });
        if (expires) |at| if (at <= context.now) return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .invalid,
            .reason = "this event has already expired",
        });
        if (event.kind == auth_kind) return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .invalid,
            .reason = "an authentication event is sent with AUTH, not EVENT",
        });
        if (self.shared.policy.auth_required_for_write and !self.isAuthenticated()) {
            return self.refuseUnauthenticated(event.id, "this relay requires authentication to publish");
        }
        if (isProtected(&event)) {
            if (!self.isAuthenticated()) return self.refuseUnauthenticated(event.id, "only its author may publish a protected event");
            if (!self.peer.?.isAuthenticatedAs(&event.pubkey)) return self.answer(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .restricted,
                .reason = "only its author may publish a protected event",
            });
        }
        if (self.shared.policy.refusal(&event)) |reason| return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .blocked,
            .reason = reason,
        });
        if (self.shared.authors) |authors| if (!authors.take(&event.pubkey, context.clock_ns)) return self.answer(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .rate_limited,
            .reason = "this author is publishing too fast",
        });

        if (kinds.classify(event.kind) == .ephemeral) {
            self.shared.hub.broadcast(context.arena, &event, null);
            return self.answer(.{ .event_id = event.id, .accepted = true });
        }

        if (self.shared.writer) |queue| {
            const reply: write_queue.Reply = .{ .subscriber = self.subscriber, .generation = self.subscriber.generation };
            queue.submit(&event, reply) catch |err| return self.answer(.{
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

        var result: store.PutResult = undefined;
        var local_id: u64 = 0;
        self.shared.store.putBatch((&event)[0..1], (&result)[0..1], (&local_id)[0..1]) catch |err|
            return self.answer(write_queue.failure(event.id, err));
        if (result == .stored) self.shared.hub.broadcast(context.arena, &event, local_id);
        return self.answer(write_queue.ok(event.id, result));
    }

    fn answer(self: *Session, ok: codec.Ok) Error!void {
        if (self.shared.metrics) |counters| counters.received(ok);
        return self.sendOk(ok);
    }

    fn closeSubscription(self: *Session, subscription_id: []const u8) void {
        self.subscriber.mutex.lockUncancelable(self.shared.io);
        defer self.subscriber.mutex.unlock(self.shared.io);
        _ = self.subscriber.registry.close(subscription_id);
    }

    fn isAuthenticated(self: *const Session) bool {
        const peer = self.peer orelse return false;
        return peer.isAuthenticated();
    }

    /// NIP-42 asks for the challenge before the first `auth-required:`.
    fn challenge(self: *Session) Error!void {
        const peer = self.peer orelse return;
        if (peer.challenged) return;
        const writer = try self.responder.begin();
        try codec.writeAuthChallenge(writer, &peer.challenge);
        try self.responder.send();
        peer.challenged = true;
    }

    fn refuseUnauthenticated(self: *Session, event_id: [32]u8, reason: []const u8) Error!void {
        try self.challenge();
        return self.sendOk(.{ .event_id = event_id, .accepted = false, .prefix = .auth_required, .reason = reason });
    }

    fn authenticate(self: *Session, context: Context, event: Event, serialized_length: usize) Error!void {
        const peer = self.peer orelse return self.sendOk(.{
            .event_id = event.id,
            .accepted = false,
            .prefix = .restricted,
            .reason = "this connection cannot authenticate",
        });
        var diagnostics: validation.Diagnostics = .{};
        const validator = validation.Validator{ .limits = self.shared.limits.event, .signer = context.signer };
        validator.validate(context.arena, &event, serialized_length, context.now, &diagnostics) catch |err| switch (err) {
            error.Invalid => return self.refuseAuth(event.id, diagnostics.message()),
            error.OutOfMemory => return self.sendOk(.{
                .event_id = event.id,
                .accepted = false,
                .prefix = .internal,
                .reason = "the relay ran out of memory validating this event",
            }),
        };
        if (event.kind != auth_kind) return self.refuseAuth(event.id, "an authentication event must be kind 22242");
        if (@abs(event.created_at - context.now) > auth_window_s) {
            return self.refuseAuth(event.id, "an authentication event must be created within ten minutes of now");
        }
        const answered = tagValue(&event, "challenge") orelse "";
        if (!std.mem.eql(u8, answered, &peer.challenge)) {
            return self.refuseAuth(event.id, "the authentication event does not answer this connection's challenge");
        }
        if (peer.host_len != 0) {
            const relay = tagValue(&event, "relay") orelse "";
            if (!sameRelay(relay, peer.host())) return self.refuseAuth(event.id, "the authentication event names a different relay");
        }
        peer.remember(&event.pubkey);
        return self.sendOk(.{ .event_id = event.id, .accepted = true });
    }

    fn refuseAuth(self: *Session, event_id: [32]u8, reason: []const u8) Error!void {
        return self.sendOk(.{ .event_id = event_id, .accepted = false, .prefix = .invalid, .reason = reason });
    }

    /// Runs without the subscriber's lock, which fan-out needs; live events arriving meanwhile are held.
    fn subscribe(self: *Session, context: Context, req: codec.ClientMessage.Req) Error!void {
        if (self.peer) |peer| if (peer.rates) |*rates| if (!rates.subscription(context.clock_ns)) {
            self.closeSubscription(req.subscription_id);
            return self.sendClosed(req.subscription_id, .rate_limited, "this connection is opening subscriptions too fast");
        };
        if (self.shared.policy.auth_required_for_read and !self.isAuthenticated()) {
            self.closeSubscription(req.subscription_id);
            try self.challenge();
            return self.sendClosed(req.subscription_id, .auth_required, "this relay requires authentication to subscribe");
        }
        const opened = opened: {
            self.subscriber.mutex.lockUncancelable(self.shared.io);
            defer self.subscriber.mutex.unlock(self.shared.io);
            self.subscriber.registry.open(req.subscription_id, req.filters) catch |err| {
                if (err == error.OutOfMemory) _ = self.subscriber.registry.close(req.subscription_id);
                break :opened err;
            };
            self.subscriber.registry.hold(req.subscription_id);
            break :opened {};
        };
        opened catch |err| return switch (err) {
            error.TooMany => self.sendClosed(
                req.subscription_id,
                .blocked,
                "this connection already holds as many subscriptions as it may",
            ),
            error.OutOfMemory => self.sendClosed(
                req.subscription_id,
                .internal,
                "the relay ran out of memory opening this subscription",
            ),
        };

        var sink: EventSink = .{
            .session = self,
            .subscription_id = req.subscription_id,
        };
        const bounded = subscriptions.resolveLimits(context.arena, req.filters, self.shared.limits.subscription) catch {
            self.closeSubscription(req.subscription_id);
            return self.sendClosed(
                req.subscription_id,
                .internal,
                "the relay ran out of memory opening this subscription",
            );
        };

        var watermark: u64 = 0;
        var exhausted = false;
        var store_sink = sink.sink();
        store_sink.watermark = &watermark;
        store_sink.now = context.now;
        store_sink.exhausted = &exhausted;
        const query_started = std.Io.Timestamp.now(self.shared.io, .awake);
        defer if (self.shared.metrics) |counters| {
            counters.query.observe(elapsed(self.shared.io, query_started));
            if (exhausted) counters.exhausted();
        };
        self.shared.store.query(bounded, store_sink) catch |err| switch (err) {
            error.Abort => return sink.failure orelse error.WriteFailed,
            error.OutOfMemory, error.Backend => {
                self.closeSubscription(req.subscription_id);
                return self.sendClosed(
                    req.subscription_id,
                    .internal,
                    "the store could not answer this subscription",
                );
            },
        };

        {
            self.subscriber.mutex.lockUncancelable(self.shared.io);
            defer self.subscriber.mutex.unlock(self.shared.io);
            self.subscriber.registry.setWatermark(req.subscription_id, watermark);
        }
        try self.sendEose(req.subscription_id);
        try self.sendHeld(req.subscription_id, watermark);
    }

    fn sendHeld(self: *Session, subscription_id: []const u8, watermark: u64) Error!void {
        while (true) {
            var released = released: {
                self.subscriber.mutex.lockUncancelable(self.shared.io);
                defer self.subscriber.mutex.unlock(self.shared.io);
                const released = self.subscriber.registry.release(subscription_id);
                if (released == .overflowed) _ = self.subscriber.registry.close(subscription_id);
                break :released released;
            };
            switch (released) {
                .live, .gone => return,
                .overflowed => return self.sendClosed(
                    subscription_id,
                    .internal,
                    "live events for this subscription arrived faster than they could be sent",
                ),
                .held => |*holding| {
                    defer holding.deinit(self.subscriber.registry.gpa);
                    for (holding.messages.items) |held| {
                        if (held.local_id) |id| if (id <= watermark) continue;
                        const writer = try self.responder.begin();
                        try writer.writeAll(held.message);
                        try self.responder.send();
                    }
                },
            }
        }
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

fn elapsed(io: std.Io, since: std.Io.Timestamp) u64 {
    return @intCast(@max(0, since.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));
}

fn isProtected(event: *const Event) bool {
    for (event.tags) |tag| {
        if (tag.len != 0 and std.mem.eql(u8, tag[0], "-")) return true;
    }
    return false;
}

fn tagValue(event: *const Event, name: []const u8) ?[]const u8 {
    for (event.tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], name)) return tag[1];
    }
    return null;
}

/// Compares authorities only: scheme, path, case and a default port are ignored.
fn sameRelay(url: []const u8, host: []const u8) bool {
    var rest = url;
    for ([_][]const u8{ "wss://", "ws://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(rest, scheme)) {
            rest = rest[scheme.len..];
            break;
        }
    }
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    return std.ascii.eqlIgnoreCase(withoutDefaultPort(authority), withoutDefaultPort(host));
}

fn withoutDefaultPort(authority: []const u8) []const u8 {
    for ([_][]const u8{ ":443", ":80" }) |port| {
        if (std.mem.endsWith(u8, authority, port)) return authority[0 .. authority.len - port.len];
    }
    return authority;
}

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
    send_delay_ms: u32 = 0,

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
        if (self.send_delay_ms != 0) std.Io.sleep(testing.io, .fromMilliseconds(self.send_delay_ms), .awake) catch {};
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

    const vtable: store.Store.VTable = .{ .put = put, .putBatch = putBatch, .query = query, .reap = reap, .stats = stats };

    fn reap(ptr: *anyopaque, now: i64, max: usize) store.Error!usize {
        _ = .{ ptr, now, max };
        return 0;
    }

    fn stats(ptr: *anyopaque) store.Error!store.Stats {
        _ = ptr;
        return .{ .events = 0 };
    }

    fn interface(self: *FailingStore) store.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn put(ptr: *anyopaque, event: *const Event) store.Error!store.PutResult {
        const self: *FailingStore = @ptrCast(@alignCast(ptr));
        _ = event;
        if (self.put_error) |failure| return failure;
        return .stored;
    }

    fn putBatch(ptr: *anyopaque, events: []const Event, results: []store.PutResult, local_ids: ?[]u64) store.Error!void {
        _ = local_ids;
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

test "an event the stored phase already sent is not delivered live as well" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    try harness.handle("[\"REQ\",\"before\",{}]");
    const event = try harness.signedEvent("raced");
    var result: store.PutResult = undefined;
    var local_id: u64 = 0;
    try harness.shared.store.putBatch((&event)[0..1], (&result)[0..1], (&local_id)[0..1]);
    try testing.expectEqual(store.PutResult.stored, result);

    harness.recorder.clear();
    try harness.handle("[\"REQ\",\"after\",{}]");
    try testing.expectEqual(@as(usize, 2), harness.recorder.messages.items.len);

    harness.shared.hub.broadcast(harness.arena(), &event, local_id);
    try testing.expectEqual(@as(usize, 1), harness.delivered.items.len);
    try testing.expect(std.mem.startsWith(u8, harness.delivered.items[0], "[\"EVENT\",\"before\","));
}

/// Publishes live events after the query has read, as if they were committed during it.
const RacingStore = struct {
    inner: store.Store,
    connections: *hub.Hub,
    arena: std.mem.Allocator,
    live: []const struct { event: Event, local_id: ?u64 },

    const vtable: store.Store.VTable = .{ .put = put, .putBatch = putBatch, .query = query, .reap = reap, .stats = stats };

    fn reap(ptr: *anyopaque, now: i64, max: usize) store.Error!usize {
        const self: *RacingStore = @ptrCast(@alignCast(ptr));
        return self.inner.reap(now, max);
    }

    fn stats(ptr: *anyopaque) store.Error!store.Stats {
        const self: *RacingStore = @ptrCast(@alignCast(ptr));
        return self.inner.stats();
    }

    fn interface(self: *RacingStore) store.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn put(ptr: *anyopaque, event: *const Event) store.Error!store.PutResult {
        const self: *RacingStore = @ptrCast(@alignCast(ptr));
        return self.inner.put(event);
    }

    fn putBatch(ptr: *anyopaque, events: []const Event, results: []store.PutResult, local_ids: ?[]u64) store.Error!void {
        const self: *RacingStore = @ptrCast(@alignCast(ptr));
        return self.inner.putBatch(events, results, local_ids);
    }

    fn query(ptr: *anyopaque, filters: []const nostr.filter.Filter, sink: store.Sink) store.QueryError!void {
        const self: *RacingStore = @ptrCast(@alignCast(ptr));
        try self.inner.query(filters, sink);
        for (self.live) |live| self.connections.broadcast(self.arena, &live.event, live.local_id);
    }
};

test "live events arriving during the stored phase follow EOSE, minus what the snapshot held" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();

    const stored = try harness.signedEventAt(test_now - 10, "stored");
    var result: store.PutResult = undefined;
    var stored_id: u64 = 0;
    try harness.shared.store.putBatch((&stored)[0..1], (&result)[0..1], (&stored_id)[0..1]);

    var racing: RacingStore = .{
        .inner = harness.shared.store,
        .connections = &harness.connections,
        .arena = harness.arena(),
        .live = &.{
            .{ .event = stored, .local_id = stored_id },
            .{ .event = try harness.signedEventAt(test_now, "committed meanwhile"), .local_id = stored_id + 1 },
            .{ .event = try harness.signedEventAt(test_now, "ephemeral meanwhile"), .local_id = null },
        },
    };
    harness.shared.store = racing.interface();

    try harness.handle("[\"REQ\",\"s\",{}]");

    const sent = harness.recorder.messages.items;
    try testing.expectEqual(@as(usize, 4), sent.len);
    try testing.expect(std.mem.indexOf(u8, sent[0], "\"stored\"") != null);
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", sent[1]);
    try testing.expect(std.mem.indexOf(u8, sent[2], "committed meanwhile") != null);
    try testing.expect(std.mem.indexOf(u8, sent[3], "ephemeral meanwhile") != null);
    try testing.expectEqual(@as(usize, 0), harness.delivered.items.len);
    try testing.expect(harness.subscriber.registry.find("s").?.holding == null);

    harness.shared.hub.broadcast(harness.arena(), &(try harness.signedEventAt(test_now, "after")), stored_id + 2);
    try testing.expectEqual(@as(usize, 1), harness.delivered.items.len);
}

test "a stored phase that holds more live events than allowed is closed with error:" {
    var harness = Harness.init(.{ .subscription = .{ .max_held_bytes = 16 } });
    try harness.start();
    defer harness.deinit();

    var racing: RacingStore = .{
        .inner = harness.shared.store,
        .connections = &harness.connections,
        .arena = harness.arena(),
        .live = &.{.{ .event = try harness.signedEventAt(test_now, "too much to hold"), .local_id = 1 }},
    };
    harness.shared.store = racing.interface();

    try harness.handle("[\"REQ\",\"s\",{}]");

    const sent = harness.recorder.messages.items;
    try testing.expectEqual(@as(usize, 2), sent.len);
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", sent[0]);
    try testing.expect(std.mem.startsWith(u8, sent[1], "[\"CLOSED\",\"s\",\"error:"));
    try testing.expectEqual(@as(usize, 0), harness.subscriber.registry.count());
}

test "an event the policy refuses is answered with blocked: and not stored" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();
    harness.shared.policy = .{ .blocked_kinds = &.{1} };

    try harness.handle(try harness.eventMessage(try harness.signedEvent("refused")));
    try testing.expect(std.mem.indexOf(u8, harness.recorder.only(), ",false,\"blocked: this kind is not accepted here\"]") != null);

    harness.recorder.clear();
    try harness.handle("[\"REQ\",\"s\",{}]");
    try testing.expectEqualStrings("[\"EOSE\",\"s\"]", harness.recorder.only());
}

test "the validation metric times the validator alone, not the answer that follows" {
    var harness = Harness.init(.{});
    try harness.start();
    defer harness.deinit();
    var counters: metrics.Metrics = .{};
    harness.shared.metrics = &counters;
    harness.recorder.send_delay_ms = 200;

    try harness.handle(try harness.eventMessage(try harness.signedEvent("timed")));
    try testing.expectEqual(@as(u64, 1), counters.events_received[@intFromEnum(metrics.Outcome.accepted)].load(.monotonic));
    try testing.expect(counters.validation.sum_ns.load(.monotonic) < 100 * std.time.ns_per_ms);
}
