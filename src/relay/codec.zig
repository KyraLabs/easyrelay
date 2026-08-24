//! The relay's half of the NIP-01 wire format: decoding what a client sends
//! and encoding what the relay answers.
//!
//! It is first-party rather than adapted. `zig-nostr`'s `message.zig` speaks
//! the client's half — it encodes `EVENT`, `REQ` and `CLOSE` and parses `OK`,
//! `EOSE`, `CLOSED` and `NOTICE` — and the two halves do not overlap anywhere.
//! That is not a gap in the dependency; a client reads exactly what this module
//! writes. It does make the dependency an oracle worth having, and the tests
//! below use it as one: everything encoded here is parsed back with its
//! `parseRelayMessage`, and everything decoded here was built with its
//! encoders. A codec tested only against itself agrees with itself.
//!
//! Decoding allocates in the per-request arena and borrows from the message
//! bytes: a subscription id and a tag value point into the buffer the frame
//! arrived in, which the caller must keep alive until it is done with the
//! message.

const std = @import("std");
const nostr = @import("nostr");

const diag = @import("diagnostics.zig");
const filters = @import("filter.zig");

const Event = nostr.event.Event;
const Filter = nostr.filter.Filter;

pub const Error = error{
    /// The bytes are not a message this relay can act on: not JSON, not an
    /// array, or the wrong shape for the type it claims to be.
    MalformedMessage,
    /// A message type the protocol defines and this relay does not implement
    /// yet. Distinct from an unknown type because "not yet" and "never" are
    /// different answers for the client.
    UnsupportedMessage,
    OutOfMemory,
};

/// From docs/protocol.md#structural-limits, spelled as docs/configuration.md
/// spells them so that Phase 2's file maps onto this without a translation
/// table.
pub const Limits = struct {
    max_subid_length: usize = 64,
    max_filters: usize = 10,
};

pub const Reason = enum {
    not_json,
    not_an_array,
    missing_type,
    unknown_type,
    unsupported_type,
    wrong_shape,
    subscription_id_empty,
    subscription_id_too_long,
    too_many_filters,
    malformed_event,
    malformed_filter,
};

pub const Diagnostics = diag.Diagnostics(Reason);

fn malformed(
    diagnostics: *Diagnostics,
    reason: Reason,
    comptime format: []const u8,
    args: anytype,
) Error {
    diagnostics.fail(reason, format, args);
    return error.MalformedMessage;
}

fn unsupported(
    diagnostics: *Diagnostics,
    comptime format: []const u8,
    args: anytype,
) Error {
    diagnostics.fail(.unsupported_type, format, args);
    return error.UnsupportedMessage;
}

// -- Client to relay --------------------------------------------------------

pub const ClientMessage = union(enum) {
    event: Event,
    req: Req,
    close: Close,

    pub const Req = struct {
        subscription_id: []const u8,
        /// Possibly empty: `["REQ","sub"]` asks for nothing, and the relay
        /// answers it with `EOSE` rather than with an error.
        filters: []const Filter,
    };

    pub const Close = struct {
        subscription_id: []const u8,
    };
};

pub fn decode(
    arena: std.mem.Allocator,
    text: []const u8,
    limits: Limits,
    diagnostics: *Diagnostics,
) Error!ClientMessage {
    // `std.json`'s value parser is iterative — it keeps its nesting on the
    // heap rather than on the call stack — so a deeply nested message costs
    // memory bounded by the transport's message limit rather than a crash.
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return malformed(diagnostics, .not_json, "message is not valid JSON", .{}),
    };

    const array = switch (value) {
        .array => |array| array.items,
        else => return malformed(diagnostics, .not_an_array, "a message must be a JSON array", .{}),
    };
    if (array.len == 0) {
        return malformed(diagnostics, .missing_type, "a message must name its type first", .{});
    }
    const message_type = switch (array[0]) {
        .string => |message_type| message_type,
        else => return malformed(diagnostics, .missing_type, "a message type must be a string", .{}),
    };

    if (std.mem.eql(u8, message_type, "EVENT")) return decodeEvent(arena, array, diagnostics);
    if (std.mem.eql(u8, message_type, "REQ")) return decodeReq(arena, array, limits, diagnostics);
    if (std.mem.eql(u8, message_type, "CLOSE")) return decodeClose(array, limits, diagnostics);

    for ([_][]const u8{ "AUTH", "COUNT", "NEG-OPEN", "NEG-MSG", "NEG-CLOSE" }) |known| {
        if (std.mem.eql(u8, message_type, known)) {
            return unsupported(diagnostics, "this relay does not support {s} yet", .{known});
        }
    }
    return malformed(
        diagnostics,
        .unknown_type,
        "unknown message type \"{s}\"",
        .{shorten(message_type, 24)},
    );
}

fn decodeEvent(
    arena: std.mem.Allocator,
    array: []const std.json.Value,
    diagnostics: *Diagnostics,
) Error!ClientMessage {
    if (array.len != 2) {
        return malformed(diagnostics, .wrong_shape, "EVENT carries exactly one event", .{});
    }
    const event = nostr.event.fromValueLeaky(arena, array[1]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return malformed(
            diagnostics,
            .malformed_event,
            "the event is missing a field or has one of the wrong type",
            .{},
        ),
    };
    return .{ .event = event };
}

fn decodeReq(
    arena: std.mem.Allocator,
    array: []const std.json.Value,
    limits: Limits,
    diagnostics: *Diagnostics,
) Error!ClientMessage {
    if (array.len < 2) {
        return malformed(diagnostics, .wrong_shape, "REQ carries a subscription id and its filters", .{});
    }
    const subscription_id = try decodeSubscriptionId(array[1], limits, diagnostics);
    // From here on the failure has a subscription id to name, which is what
    // lets the caller answer `CLOSED` rather than `NOTICE`.
    diagnostics.subject = subscription_id;

    const count = array.len - 2;
    if (count > limits.max_filters) {
        return malformed(
            diagnostics,
            .too_many_filters,
            "REQ carries {d} filters, over the limit of {d}",
            .{ count, limits.max_filters },
        );
    }

    const decoded = try arena.alloc(Filter, count);
    for (array[2..], decoded, 0..) |value, *target, index| {
        var filter_diagnostics: filters.Diagnostics = .{};
        target.* = filters.decode(arena, value, &filter_diagnostics) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedFilter => return malformed(
                diagnostics,
                .malformed_filter,
                "filter {d}: {s}",
                .{ index, shorten(filter_diagnostics.message(), 120) },
            ),
        };
    }
    return .{ .req = .{ .subscription_id = subscription_id, .filters = decoded } };
}

fn decodeClose(
    array: []const std.json.Value,
    limits: Limits,
    diagnostics: *Diagnostics,
) Error!ClientMessage {
    if (array.len != 2) {
        return malformed(diagnostics, .wrong_shape, "CLOSE carries exactly one subscription id", .{});
    }
    const subscription_id = try decodeSubscriptionId(array[1], limits, diagnostics);
    diagnostics.subject = subscription_id;
    return .{ .close = .{ .subscription_id = subscription_id } };
}

fn decodeSubscriptionId(
    value: std.json.Value,
    limits: Limits,
    diagnostics: *Diagnostics,
) Error![]const u8 {
    const subscription_id = switch (value) {
        .string => |subscription_id| subscription_id,
        else => return malformed(diagnostics, .wrong_shape, "a subscription id must be a string", .{}),
    };
    if (subscription_id.len == 0) {
        return malformed(diagnostics, .subscription_id_empty, "a subscription id must not be empty", .{});
    }
    if (subscription_id.len > limits.max_subid_length) {
        return malformed(
            diagnostics,
            .subscription_id_too_long,
            "subscription id is {d} characters, over the limit of {d}",
            .{ subscription_id.len, limits.max_subid_length },
        );
    }
    return subscription_id;
}

/// Keeps client-supplied text from filling a diagnostic and pushing out the
/// part that explains the failure.
fn shorten(text: []const u8, limit: usize) []const u8 {
    return text[0..@min(text.len, limit)];
}

// -- Relay to client --------------------------------------------------------

/// The machine-readable prefixes from
/// docs/protocol.md#machine-readable-result-prefixes.
pub const Prefix = enum {
    duplicate,
    pow,
    blocked,
    rate_limited,
    invalid,
    restricted,
    auth_required,
    /// Spelled `error:` on the wire; `error` is a keyword here.
    internal,

    /// The token including its colon, exactly as the document publishes it.
    pub fn text(self: Prefix) []const u8 {
        return switch (self) {
            .duplicate => "duplicate:",
            .pow => "pow:",
            .blocked => "blocked:",
            .rate_limited => "rate-limited:",
            .invalid => "invalid:",
            .restricted => "restricted:",
            .auth_required => "auth-required:",
            .internal => "error:",
        };
    }
};

pub const Ok = struct {
    event_id: [32]u8,
    accepted: bool,
    /// Required when `accepted` is false. `duplicate:` travels with `true`,
    /// because the client's event is on the relay, which is what it asked for.
    prefix: ?Prefix = null,
    reason: []const u8 = "",
};

pub fn writeOk(writer: *std.Io.Writer, ok: Ok) std.Io.Writer.Error!void {
    // docs/protocol.md: every `OK` carrying false begins with a prefix. A
    // rejection a client cannot classify is one it will retry forever.
    std.debug.assert(ok.accepted or ok.prefix != null);

    const id = std.fmt.bytesToHex(ok.event_id, .lower);
    try writer.writeAll("[\"OK\",\"");
    try writer.writeAll(&id);
    try writer.writeAll(if (ok.accepted) "\",true," else "\",false,");
    try writeReason(writer, ok.prefix, ok.reason);
    try writer.writeByte(']');
}

pub fn writeEvent(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    subscription_id: []const u8,
    event: Event,
) (std.Io.Writer.Error || error{OutOfMemory})!void {
    // The dependency serializes an event into an owned slice and offers no
    // append-into-writer variant, so this costs one allocation. It comes from
    // the per-request arena.
    const body = try nostr.event.toJson(gpa, event);
    defer gpa.free(body);
    try writeEventEnvelope(writer, subscription_id, body);
}

/// The same message from an event that is already serialized.
///
/// Fan-out sends one event to many subscriptions, which differ only in the id
/// they carry, so it serializes once and calls this for each. That path is the
/// relay's hot one: every accepted event is written to every subscriber that
/// wants it.
pub fn writeEventEnvelope(
    writer: *std.Io.Writer,
    subscription_id: []const u8,
    serialized_event: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("[\"EVENT\",");
    try std.json.Stringify.encodeJsonString(subscription_id, .{}, writer);
    try writer.writeByte(',');
    try writer.writeAll(serialized_event);
    try writer.writeByte(']');
}

pub fn writeEose(writer: *std.Io.Writer, subscription_id: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[\"EOSE\",");
    try std.json.Stringify.encodeJsonString(subscription_id, .{}, writer);
    try writer.writeByte(']');
}

pub fn writeClosed(
    writer: *std.Io.Writer,
    subscription_id: []const u8,
    prefix: Prefix,
    reason: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("[\"CLOSED\",");
    try std.json.Stringify.encodeJsonString(subscription_id, .{}, writer);
    try writer.writeByte(',');
    try writeReason(writer, prefix, reason);
    try writer.writeByte(']');
}

pub fn writeNotice(writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[\"NOTICE\",");
    try std.json.Stringify.encodeJsonString(message, .{}, writer);
    try writer.writeByte(']');
}

/// `"<prefix>: <reason>"`, escaped for the wire. This is ordinary JSON string
/// escaping and deliberately not NIP-01's canonical escaping: the canonical
/// form exists to make an id reproducible, and nothing here is hashed.
fn writeReason(
    writer: *std.Io.Writer,
    prefix: ?Prefix,
    reason: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    if (prefix) |present| {
        try writer.writeAll(present.text());
        if (reason.len != 0) try writer.writeByte(' ');
    }
    try std.json.Stringify.encodeJsonStringChars(reason, .{}, writer);
    try writer.writeByte('"');
}

const testing = std.testing;

const hex_a = "aa" ** 32;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: Diagnostics = .{},
    limits: Limits = .{},

    fn init(limits: Limits) Harness {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .limits = limits,
        };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn read(self: *Harness, text: []const u8) Error!ClientMessage {
        return decode(self.arena(), text, self.limits, &self.diagnostics);
    }
};

fn signedEvent(arena: std.mem.Allocator, signer: nostr.keys.Signer) !Event {
    const keypair = try signer.keyPairFromSecretKey([_]u8{9} ** 32);
    return nostr.event.create(arena, signer, keypair, 1700000000, 1, &.{}, "hello", null);
}

test "an EVENT a client library produced decodes to the same event" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const event = try signedEvent(harness.arena(), signer);
    const wire = try nostr.message.encodeEvent(harness.arena(), event);

    const message = try harness.read(wire);
    try testing.expectEqualSlices(u8, &event.id, &message.event.id);
    try testing.expectEqualStrings("hello", message.event.content);
}

test "a REQ a client library produced decodes to the same filters" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const sent = [_]Filter{
        .{ .kinds = &.{1}, .limit = 10 },
        .{ .authors = &.{[_]u8{0xaa} ** 32} },
    };
    const wire = try nostr.message.encodeReq(harness.arena(), "sub-1", &sent);

    const message = try harness.read(wire);
    try testing.expectEqualStrings("sub-1", message.req.subscription_id);
    try testing.expectEqual(@as(usize, 2), message.req.filters.len);
    try testing.expectEqual(@as(u16, 1), message.req.filters[0].kinds.?[0]);
    try testing.expectEqual(@as(u32, 10), message.req.filters[0].limit.?);
    try testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 32, &message.req.filters[1].authors.?[0]);
}

test "a CLOSE decodes to its subscription id" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const wire = try nostr.message.encodeClose(harness.arena(), "sub-1");
    const message = try harness.read(wire);
    try testing.expectEqualStrings("sub-1", message.close.subscription_id);
}

test "a REQ with no filters is a request for nothing, not an error" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const message = try harness.read("[\"REQ\",\"sub-1\"]");
    try testing.expectEqual(@as(usize, 0), message.req.filters.len);
}

test "input that is not a message is refused with the reason why" {
    const cases = [_]struct { text: []const u8, reason: Reason }{
        .{ .text = "not json at all", .reason = .not_json },
        .{ .text = "{\"type\":\"EVENT\"}", .reason = .not_an_array },
        .{ .text = "[]", .reason = .missing_type },
        .{ .text = "[42]", .reason = .missing_type },
        .{ .text = "[\"NOPE\"]", .reason = .unknown_type },
        .{ .text = "[\"EVENT\"]", .reason = .wrong_shape },
        .{ .text = "[\"EVENT\",{},{}]", .reason = .wrong_shape },
        .{ .text = "[\"EVENT\",{\"id\":\"short\"}]", .reason = .malformed_event },
        .{ .text = "[\"CLOSE\"]", .reason = .wrong_shape },
        .{ .text = "[\"CLOSE\",7]", .reason = .wrong_shape },
        .{ .text = "[\"CLOSE\",\"\"]", .reason = .subscription_id_empty },
        .{ .text = "[\"REQ\"]", .reason = .wrong_shape },
    };

    for (cases) |case| {
        var harness = Harness.init(.{});
        defer harness.deinit();

        try testing.expectError(error.MalformedMessage, harness.read(case.text));
        testing.expectEqual(case.reason, harness.diagnostics.reason.?) catch |err| {
            std.debug.print("input {s} reported {s}\n", .{ case.text, @tagName(harness.diagnostics.reason.?) });
            return err;
        };
        try testing.expect(harness.diagnostics.message().len != 0);
    }
}

test "a subscription id over the limit is refused" {
    var harness = Harness.init(.{ .max_subid_length = 4 });
    defer harness.deinit();

    try testing.expectError(error.MalformedMessage, harness.read("[\"CLOSE\",\"toolong\"]"));
    try testing.expectEqual(Reason.subscription_id_too_long, harness.diagnostics.reason.?);
    try testing.expect(std.mem.indexOf(u8, harness.diagnostics.message(), "4") != null);
}

test "more filters than the limit allows is refused" {
    var harness = Harness.init(.{ .max_filters = 2 });
    defer harness.deinit();

    try testing.expectError(error.MalformedMessage, harness.read("[\"REQ\",\"s\",{},{},{}]"));
    try testing.expectEqual(Reason.too_many_filters, harness.diagnostics.reason.?);
}

test "a malformed filter names which filter it was" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    try testing.expectError(
        error.MalformedMessage,
        harness.read("[\"REQ\",\"s\",{},{\"authors\":[\"nothex\"]}]"),
    );
    try testing.expectEqual(Reason.malformed_filter, harness.diagnostics.reason.?);
    try testing.expect(std.mem.startsWith(u8, harness.diagnostics.message(), "filter 1:"));
}

test "a message type the protocol defines and this relay lacks is refused as unsupported" {
    for ([_][]const u8{ "AUTH", "COUNT", "NEG-OPEN", "NEG-MSG", "NEG-CLOSE" }) |message_type| {
        var harness = Harness.init(.{});
        defer harness.deinit();

        const text = try std.fmt.allocPrint(harness.arena(), "[\"{s}\",\"s\"]", .{message_type});
        try testing.expectError(error.UnsupportedMessage, harness.read(text));
        try testing.expectEqual(Reason.unsupported_type, harness.diagnostics.reason.?);
    }
}

// -- Encoding, checked by parsing the result with the dependency's client ----

test "an accepted OK parses back as accepted" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeOk(&out.writer, .{ .event_id = [_]u8{0xaa} ** 32, .accepted = true });

    var parsed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer parsed.deinit();

    try testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 32, &parsed.value.ok.event_id);
    try testing.expect(parsed.value.ok.accepted);
    try testing.expectEqualStrings("", parsed.value.ok.message);
}

test "a rejected OK carries its prefix and reason" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeOk(&out.writer, .{
        .event_id = [_]u8{0xbb} ** 32,
        .accepted = false,
        .prefix = .invalid,
        .reason = "signature does not verify",
    });

    var parsed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer parsed.deinit();

    try testing.expect(!parsed.value.ok.accepted);
    try testing.expectEqualStrings("invalid: signature does not verify", parsed.value.ok.message);
}

test "duplicate travels with true, as docs/protocol.md requires" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeOk(&out.writer, .{
        .event_id = [_]u8{0xcc} ** 32,
        .accepted = true,
        .prefix = .duplicate,
        .reason = "already stored",
    });

    var parsed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer parsed.deinit();

    try testing.expect(parsed.value.ok.accepted);
    try testing.expectEqualStrings("duplicate: already stored", parsed.value.ok.message);
}

test "every prefix is spelled the way docs/protocol.md publishes it" {
    try testing.expectEqualStrings("duplicate:", Prefix.duplicate.text());
    try testing.expectEqualStrings("pow:", Prefix.pow.text());
    try testing.expectEqualStrings("blocked:", Prefix.blocked.text());
    try testing.expectEqualStrings("rate-limited:", Prefix.rate_limited.text());
    try testing.expectEqualStrings("invalid:", Prefix.invalid.text());
    try testing.expectEqualStrings("restricted:", Prefix.restricted.text());
    try testing.expectEqualStrings("auth-required:", Prefix.auth_required.text());
    try testing.expectEqualStrings("error:", Prefix.internal.text());
}

test "an EVENT parses back as the event that was sent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const event = try signedEvent(arena, signer);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeEvent(&out.writer, arena, "sub-1", event);

    var parsed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer parsed.deinit();

    try testing.expectEqualStrings("sub-1", parsed.value.event.subscription_id);
    try testing.expectEqualSlices(u8, &event.id, &parsed.value.event.event.id);
    try testing.expect(try nostr.event.verify(arena, signer, parsed.value.event.event));
}

test "EOSE, CLOSED and NOTICE parse back" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeEose(&out.writer, "sub-1");
    var eose = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer eose.deinit();
    try testing.expectEqualStrings("sub-1", eose.value.eose.subscription_id);

    out.writer.end = 0;
    try writeClosed(&out.writer, "sub-1", .invalid, "filter 0: bad hex");
    var closed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer closed.deinit();
    try testing.expectEqualStrings("sub-1", closed.value.closed.subscription_id);
    try testing.expectEqualStrings("invalid: filter 0: bad hex", closed.value.closed.message);

    out.writer.end = 0;
    try writeNotice(&out.writer, "restarting");
    var notice = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer notice.deinit();
    try testing.expectEqualStrings("restarting", notice.value.notice.message);
}

test "a subscription id with characters that need escaping survives the round trip" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const hostile = "he said \"hi\"\\\n\x01 ✓";
    try writeEose(&out.writer, hostile);

    var parsed = try nostr.message.parseRelayMessage(testing.allocator, out.written());
    defer parsed.deinit();
    try testing.expectEqualStrings(hostile, parsed.value.eose.subscription_id);
}

test "a REQ refused after its id was read names the subscription" {
    var harness = Harness.init(.{ .max_filters = 1 });
    defer harness.deinit();

    try testing.expectError(error.MalformedMessage, harness.read("[\"REQ\",\"sub-1\",{},{}]"));
    try testing.expectEqual(Reason.too_many_filters, harness.diagnostics.reason.?);
    try testing.expectEqualStrings("sub-1", harness.diagnostics.subject.?);
}

test "a REQ refused before its id was read names nothing" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    try testing.expectError(error.MalformedMessage, harness.read("[\"REQ\",\"\",{}]"));
    try testing.expectEqual(@as(?[]const u8, null), harness.diagnostics.subject);
}
