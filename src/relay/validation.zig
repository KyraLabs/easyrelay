//! Validation of an inbound event, in the order docs/architecture.md fixes:
//! structural limits, then the `created_at` window, then the canonical id,
//! then the signature.
//!
//! The order is the design, not a detail. Signature verification is the
//! expensive step — roughly 46 µs an event, measured in Phase 0 — and an
//! unauthenticated client must not be able to reach it with input that a byte
//! comparison would have rejected. Every check before it is a length or an
//! integer comparison.
//!
//! Failure is one error, `error.Invalid`, with the reason in a `Diagnostics`
//! the caller passes in. Zig errors carry no payload and docs/protocol.md
//! requires `["OK", <id>, false, "invalid: <reason>"]` to carry a real reason,
//! so the reason travels beside the error rather than inside it.

const std = @import("std");
const nostr = @import("nostr");

const diag = @import("diagnostics.zig");

const Event = nostr.event.Event;

pub const Error = error{
    /// The event is malformed, its id does not match its content, or its
    /// signature does not verify. The client is answered `OK false` with the
    /// `invalid:` prefix and the diagnostics' message.
    Invalid,
    OutOfMemory,
};

/// The structural bounds from docs/protocol.md#structural-limits. The defaults
/// are that document's defaults; Phase 2's configuration file fills this in
/// from docs/configuration.md, whose key names these mirror deliberately.
pub const Limits = struct {
    /// Bytes the event occupied on the wire. Nothing else bounds the length of
    /// an individual tag element, which is deliberate: this bounds it
    /// transitively and one limit is easier to reason about than two.
    max_event_size: usize = 65536,
    max_event_tags: usize = 2000,
    max_content_length: usize = 65536,
    /// Seconds into the future an event may claim to have been created.
    created_at_upper_limit_s: i64 = 900,
    /// Seconds into the past. Null accepts any age, which is the default: a
    /// relay that refuses old events cannot be backfilled.
    created_at_lower_limit_s: ?i64 = null,
};

pub const Reason = enum {
    event_too_large,
    too_many_tags,
    content_too_large,
    created_at_too_far_ahead,
    created_at_too_far_behind,
    id_mismatch,
    bad_signature,
};

/// Carries the reason a validation failed back to the caller, which turns it
/// into the `OK` message.
pub const Diagnostics = diag.Diagnostics(Reason);

/// Records the reason and returns the module's error in one expression, so
/// that a check reads as a single statement and cannot record a failure
/// without returning one.
fn invalid(
    into: *Diagnostics,
    reason: Reason,
    comptime format: []const u8,
    args: anytype,
) Error {
    into.fail(reason, format, args);
    return error.Invalid;
}

pub const Validator = struct {
    limits: Limits = .{},
    /// Borrowed, and not owned: `keys.Signer` is not thread-safe for
    /// concurrent use of one instance, so each I/O thread holds its own and
    /// deinitialises it. Phase 0 found this before it could become a race.
    signer: nostr.keys.Signer,

    /// Checks `event`, which arrived as `serialized_length` bytes on the wire,
    /// against the relay's rules as of `now` (unix seconds).
    ///
    /// `now` is a parameter rather than a clock read: it makes every bound
    /// testable without waiting, and the caller reads the clock once per
    /// message instead of twice per event.
    ///
    /// `arena` is the per-request arena. Nothing allocated here outlives the
    /// call.
    pub fn validate(
        self: Validator,
        arena: std.mem.Allocator,
        event: *const Event,
        serialized_length: usize,
        now: i64,
        diagnostics: *Diagnostics,
    ) Error!void {
        if (serialized_length > self.limits.max_event_size) {
            return invalid(
                diagnostics,
                .event_too_large,
                "event is {d} bytes, over the {d} byte limit",
                .{ serialized_length, self.limits.max_event_size },
            );
        }
        if (event.tags.len > self.limits.max_event_tags) {
            return invalid(
                diagnostics,
                .too_many_tags,
                "event carries {d} tags, over the limit of {d}",
                .{ event.tags.len, self.limits.max_event_tags },
            );
        }
        if (event.content.len > self.limits.max_content_length) {
            return invalid(
                diagnostics,
                .content_too_large,
                "content is {d} bytes, over the {d} byte limit",
                .{ event.content.len, self.limits.max_content_length },
            );
        }

        // Saturating, because both bounds are configured and `now` is not: an
        // overflow here would be a rejection turning into an acceptance.
        if (event.created_at > now +| self.limits.created_at_upper_limit_s) {
            return invalid(
                diagnostics,
                .created_at_too_far_ahead,
                "created_at is more than {d} seconds in the future",
                .{self.limits.created_at_upper_limit_s},
            );
        }
        if (self.limits.created_at_lower_limit_s) |lower| {
            if (event.created_at < now -| lower) {
                return invalid(
                    diagnostics,
                    .created_at_too_far_behind,
                    "created_at is more than {d} seconds in the past",
                    .{lower},
                );
            }
        }

        const recomputed = try nostr.event.computeId(
            arena,
            event.pubkey,
            event.created_at,
            event.kind,
            event.tags,
            event.content,
        );
        if (!std.mem.eql(u8, &recomputed, &event.id)) {
            return invalid(
                diagnostics,
                .id_mismatch,
                "id does not match the canonical serialization of the event",
                .{},
            );
        }

        if (!self.signer.verifyId(event.sig, event.id, event.pubkey)) {
            return invalid(
                diagnostics,
                .bad_signature,
                "signature does not verify against the event's pubkey",
                .{},
            );
        }
    }
};

const testing = std.testing;

/// Unix seconds every test validates against. Fixed, so that no bound depends
/// on when the suite runs.
const test_now: i64 = 1_700_000_000;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    signer: nostr.keys.Signer,
    validator: Validator,
    diagnostics: Diagnostics = .{},

    fn init(limits: Limits) Harness {
        const signer = nostr.keys.Signer.init();
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .signer = signer,
            .validator = .{ .limits = limits, .signer = signer },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
        self.signer.deinit();
    }

    fn arena(self: *Harness) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn sign(
        self: *Harness,
        created_at: i64,
        tags: []const nostr.event.Tag,
        content: []const u8,
    ) !Event {
        const keypair = try self.signer.keyPairFromSecretKey([_]u8{7} ** 32);
        return nostr.event.create(self.arena(), self.signer, keypair, created_at, 1, tags, content, null);
    }

    fn check(self: *Harness, event: *const Event, serialized_length: usize) Error!void {
        return self.validator.validate(
            self.arena(),
            event,
            serialized_length,
            test_now,
            &self.diagnostics,
        );
    }
};

test "the defaults are the limits docs/protocol.md publishes" {
    const limits = Limits{};
    try testing.expectEqual(@as(usize, 65536), limits.max_event_size);
    try testing.expectEqual(@as(usize, 2000), limits.max_event_tags);
    try testing.expectEqual(@as(usize, 65536), limits.max_content_length);
    try testing.expectEqual(@as(i64, 900), limits.created_at_upper_limit_s);
    try testing.expectEqual(@as(?i64, null), limits.created_at_lower_limit_s);
}

test "a well-formed event passes" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const event = try harness.sign(test_now, &.{}, "hello");
    try harness.check(&event, 200);
    try testing.expectEqual(@as(?Reason, null), harness.diagnostics.reason);
}

test "an event over the size limit is rejected" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const event = try harness.sign(test_now, &.{}, "hello");
    try testing.expectError(error.Invalid, harness.check(&event, 65537));
    try testing.expectEqual(Reason.event_too_large, harness.diagnostics.reason.?);
}

test "an event with too many tags is rejected" {
    var harness = Harness.init(.{ .max_event_tags = 1 });
    defer harness.deinit();

    const tags = [_]nostr.event.Tag{ &.{ "e", "one" }, &.{ "p", "two" } };
    const event = try harness.sign(test_now, &tags, "");
    try testing.expectError(error.Invalid, harness.check(&event, 200));
    try testing.expectEqual(Reason.too_many_tags, harness.diagnostics.reason.?);
}

test "an event with oversized content is rejected" {
    var harness = Harness.init(.{ .max_content_length = 8 });
    defer harness.deinit();

    const event = try harness.sign(test_now, &.{}, "123456789");
    try testing.expectError(error.Invalid, harness.check(&event, 200));
    try testing.expectEqual(Reason.content_too_large, harness.diagnostics.reason.?);
}

test "created_at at the edge of the future window is accepted, past it is not" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const edge = try harness.sign(test_now + 900, &.{}, "");
    try harness.check(&edge, 200);

    const beyond = try harness.sign(test_now + 901, &.{}, "");
    try testing.expectError(error.Invalid, harness.check(&beyond, 200));
    try testing.expectEqual(Reason.created_at_too_far_ahead, harness.diagnostics.reason.?);
}

test "an old event passes by default and is rejected when a lower bound is set" {
    const ancient = test_now - 10 * 365 * 24 * 60 * 60;

    var permissive = Harness.init(.{});
    defer permissive.deinit();
    const old_event = try permissive.sign(ancient, &.{}, "");
    try permissive.check(&old_event, 200);

    var bounded = Harness.init(.{ .created_at_lower_limit_s = 3600 });
    defer bounded.deinit();
    const same_event = try bounded.sign(ancient, &.{}, "");
    try testing.expectError(error.Invalid, bounded.check(&same_event, 200));
    try testing.expectEqual(Reason.created_at_too_far_behind, bounded.diagnostics.reason.?);
}

test "an event whose id does not match its content is rejected" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    var event = try harness.sign(test_now, &.{}, "hello");
    event.id[0] ^= 0xff;

    try testing.expectError(error.Invalid, harness.check(&event, 200));
    try testing.expectEqual(Reason.id_mismatch, harness.diagnostics.reason.?);
}

test "an event with a valid id and an invalid signature is rejected" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    var event = try harness.sign(test_now, &.{}, "hello");
    event.sig[0] ^= 0xff;

    try testing.expectError(error.Invalid, harness.check(&event, 200));
    try testing.expectEqual(Reason.bad_signature, harness.diagnostics.reason.?);
}

test "the cheap checks run before the expensive one" {
    // Both events below would also fail signature verification. Reporting the
    // cheaper failure is the evidence that verification was never reached,
    // which is what keeps an unauthenticated client from spending the relay's
    // CPU on malformed input.
    var by_size = Harness.init(.{});
    defer by_size.deinit();
    var oversized = try by_size.sign(test_now, &.{}, "hello");
    oversized.sig[0] ^= 0xff;
    try testing.expectError(error.Invalid, by_size.check(&oversized, 65537));
    try testing.expectEqual(Reason.event_too_large, by_size.diagnostics.reason.?);

    var by_id = Harness.init(.{});
    defer by_id.deinit();
    var tampered = try by_id.sign(test_now, &.{}, "hello");
    tampered.id[0] ^= 0xff;
    tampered.sig[0] ^= 0xff;
    try testing.expectError(error.Invalid, by_id.check(&tampered, 200));
    try testing.expectEqual(Reason.id_mismatch, by_id.diagnostics.reason.?);
}

test "the diagnostic names the limit that was broken" {
    var harness = Harness.init(.{});
    defer harness.deinit();

    const event = try harness.sign(test_now, &.{}, "hello");
    try testing.expectError(error.Invalid, harness.check(&event, 70000));

    const message = harness.diagnostics.message();
    try testing.expect(std.mem.indexOf(u8, message, "70000") != null);
    try testing.expect(std.mem.indexOf(u8, message, "65536") != null);
}
