const std = @import("std");

pub fn Diagnostics(comptime Reason: type) type {
    return struct {
        const Self = @This();

        reason: ?Reason = null,
        subject: ?[]const u8 = null,
        message_buffer: [capacity]u8 = undefined,
        message_length: usize = 0,

        pub const capacity = 160;

        pub fn message(self: *const Self) []const u8 {
            return self.message_buffer[0..self.message_length];
        }

        pub fn fail(
            self: *Self,
            reason: Reason,
            comptime format: []const u8,
            args: anytype,
        ) void {
            self.reason = reason;
            const written = std.fmt.bufPrint(&self.message_buffer, format, args) catch blk: {
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
