const std = @import("std");

pub const Level = enum(u8) {
    @"error",
    warn,
    info,
    debug,

    fn of(level: std.log.Level) Level {
        return switch (level) {
            .err => .@"error",
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }
};

pub const Format = enum(u8) { json, text };

var current_level: std.atomic.Value(Level) = .init(.info);
var current_format: std.atomic.Value(Format) = .init(.json);

/// Takes effect for every thread from the next message on.
pub fn configure(level: Level, format: Format) void {
    current_level.store(level, .release);
    current_format.store(format, .release);
}

pub fn enabled(level: std.log.Level) bool {
    return @intFromEnum(Level.of(level)) <= @intFromEnum(current_level.load(.acquire));
}

/// For `std_options.logFn`. One line per message on stderr, written under the stderr lock so
/// lines from different threads never interleave. A message longer than the line buffer is cut.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    const io = std.Options.debug_io;
    var line_buffer: [4096]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buffer);
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    render(&line, current_format.load(.acquire), seconds, Level.of(level), @tagName(scope), format, args);

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr.file_writer.interface;
    writer.writeAll(line.buffered()) catch return;
    writer.flush() catch {};
}

fn render(
    line: *std.Io.Writer,
    format: Format,
    seconds: i64,
    level: Level,
    scope: []const u8,
    comptime message_format: []const u8,
    args: anytype,
) void {
    const reserve = 2;
    const body: []u8 = line.buffer[0 .. line.buffer.len - reserve];
    var message_buffer: [3072]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, message_format, args) catch message_buffer[0..];
    var writer: std.Io.Writer = .fixed(body);
    switch (format) {
        .json => {
            // Escaping can grow a byte sixfold; cutting first keeps the object whole.
            const fits = utf8Prefix(message, (body.len - 128) / 6);
            writer.writeAll("{\"time\":\"") catch {};
            writeTime(&writer, seconds) catch {};
            writer.print("\",\"level\":\"{t}\",\"scope\":\"{s}\",\"message\":", .{ level, scope }) catch {};
            std.json.Stringify.encodeJsonString(fits, .{}, &writer) catch {};
            writer.writeAll("}") catch {};
        },
        .text => {
            writeTime(&writer, seconds) catch {};
            writer.print(" {t} {s}: {s}", .{ level, scope, message }) catch {};
        },
    }
    line.end = writer.end;
    line.writeAll("\n") catch {};
}

fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

/// RFC 3339 in UTC, to the second.
fn writeTime(writer: *std.Io.Writer, seconds: i64) std.Io.Writer.Error!void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

const testing = std.testing;

test "a JSON line is one valid object naming time, level, scope and message" {
    var buffer: [512]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    render(&line, .json, 1_700_000_000, .warn, "server", "conn={d} said \"{s}\"", .{ 7, "hi\n" });
    const text = line.buffered();
    try testing.expect(std.mem.endsWith(u8, text, "}\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", object.get("time").?.string);
    try testing.expectEqualStrings("warn", object.get("level").?.string);
    try testing.expectEqualStrings("server", object.get("scope").?.string);
    try testing.expectEqualStrings("conn=7 said \"hi\n\"", object.get("message").?.string);
}

test "a text line reads naturally" {
    var buffer: [512]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    render(&line, .text, 0, .@"error", "main", "stopped: {t}", .{error.Boom});
    try testing.expectEqualStrings("1970-01-01T00:00:00Z error main: stopped: Boom\n", line.buffered());
}

test "an overlong message is cut, and the line still ends in a newline" {
    var buffer: [256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    render(&line, .text, 0, .info, "x", "{s}", .{"y" ** 400});
    try testing.expect(std.mem.endsWith(u8, line.buffered(), "\n"));

    line = .fixed(&buffer);
    render(&line, .json, 0, .info, "x", "{s}", .{"\x01\u{e9}" ** 200});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line.buffered(), .{});
    defer parsed.deinit();
}

test "messages above the configured level are dropped" {
    defer configure(.info, .json);
    configure(.warn, .text);
    try testing.expect(enabled(.err));
    try testing.expect(enabled(.warn));
    try testing.expect(!enabled(.info));
    configure(.debug, .text);
    try testing.expect(enabled(.debug));
}
