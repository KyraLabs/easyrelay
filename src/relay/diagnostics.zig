//! The Diagnostics pattern: how a failure explains itself.
//!
//! Zig errors carry no payload, and docs/protocol.md requires a rejected
//! `EVENT` to be answered with `["OK", <id>, false, "invalid: <reason>"]` and
//! a terminated subscription with `["CLOSED", <id>, "<prefix>: <reason>"]`.
//! An error alone cannot say which limit was broken or which filter field was
//! malformed, so the reason travels beside it: the caller passes a
//! `Diagnostics` in, the callee fills it before returning, and the connection
//! turns it into a wire message.
//!
//! Both halves are carried deliberately. `reason` is an enum, for metrics and
//! for tests, which must not break when the wording improves. The message is
//! the human half, with the offending values substituted — a client that is
//! told only `invalid:` has to guess.

const std = @import("std");

/// Diagnostics over a module's own reason enum. Generic because each layer
/// classifies its failures differently while formatting them identically, and
/// because there is no allocation here: the buffer is inline, so a diagnostic
/// costs nothing on the path where nothing fails.
pub fn Diagnostics(comptime Reason: type) type {
    return struct {
        const Self = @This();

        /// Null until something fails.
        reason: ?Reason = null,
        message_buffer: [capacity]u8 = undefined,
        message_length: usize = 0,

        /// Long enough for every message the relay produces with its values
        /// substituted, and small enough to sit inline in per-connection
        /// state.
        pub const capacity = 160;

        /// What follows the machine-readable prefix in the wire message.
        /// Empty until something fails.
        pub fn message(self: *const Self) []const u8 {
            return self.message_buffer[0..self.message_length];
        }

        /// Records why something failed. The caller returns its own error
        /// afterwards, because the error set belongs to the caller's module.
        pub fn fail(
            self: *Self,
            reason: Reason,
            comptime format: []const u8,
            args: anytype,
        ) void {
            self.reason = reason;
            const written = std.fmt.bufPrint(&self.message_buffer, format, args) catch blk: {
                // Unreachable with the formats in use, all of which are short.
                // Should a future one overflow, the client still learns what
                // failed rather than receiving an empty reason.
                const name = @tagName(reason);
                @memcpy(self.message_buffer[0..name.len], name);
                break :blk self.message_buffer[0..name.len];
            };
            self.message_length = written.len;
        }
    };
}

const testing = std.testing;

const TestReason = enum { too_big, malformed };

test "a fresh diagnostics carries no reason and an empty message" {
    const diagnostics: Diagnostics(TestReason) = .{};
    try testing.expectEqual(@as(?TestReason, null), diagnostics.reason);
    try testing.expectEqualStrings("", diagnostics.message());
}

test "failing records both halves" {
    var diagnostics: Diagnostics(TestReason) = .{};
    diagnostics.fail(.too_big, "value is {d}, over the limit of {d}", .{ 12, 10 });

    try testing.expectEqual(TestReason.too_big, diagnostics.reason.?);
    try testing.expectEqualStrings("value is 12, over the limit of 10", diagnostics.message());
}

test "a message too long for the buffer falls back to the reason" {
    var diagnostics: Diagnostics(TestReason) = .{};
    diagnostics.fail(.malformed, "{s}", .{"x" ** (Diagnostics(TestReason).capacity + 1)});

    try testing.expectEqual(TestReason.malformed, diagnostics.reason.?);
    try testing.expectEqualStrings("malformed", diagnostics.message());
}
