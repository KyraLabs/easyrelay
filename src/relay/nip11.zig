const std = @import("std");

const config = @import("../config.zig");
const root = @import("../root.zig");

const nips_table = @embedFile("nips.md");

pub const software = "https://github.com/KyraLabs/easyrelay";
pub const media_type = "application/nostr+json";

/// The NIPs docs/nips.md marks `supported`, so the document cannot advertise more than the table.
pub const supported_nips: []const u16 = parseSupported(nips_table);

fn parseSupported(comptime table: []const u8) []const u16 {
    @setEvalBranchQuota(200_000);
    comptime var found: []const u16 = &.{};
    comptime var lines = std.mem.splitScalar(u8, table, '\n');
    inline while (comptime lines.next()) |line| {
        if (comptime !std.mem.startsWith(u8, line, "| [")) continue;
        const close = comptime std.mem.indexOfScalar(u8, line, ']').?;
        const number = comptime std.fmt.parseInt(u16, line[3..close], 10) catch continue;
        comptime var columns = std.mem.splitScalar(u8, line, '|');
        _ = comptime columns.next();
        _ = comptime columns.next();
        _ = comptime columns.next();
        const status = comptime std.mem.trim(u8, columns.next().?, " ");
        if (comptime std.mem.eql(u8, status, "supported")) found = found ++ .{number};
    }
    const result = found[0..found.len].*;
    return &result;
}

/// The full HTTP responses, rendered once at startup and served as they are.
pub const Responses = struct {
    document: []const u8,
    preflight: []const u8,

    pub fn render(arena: std.mem.Allocator, settings: config.Config) error{OutOfMemory}!Responses {
        const body = try renderDocument(arena, settings);
        return .{
            .document = try std.fmt.allocPrint(arena, "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: " ++ media_type ++ "\r\n" ++ cors ++
                "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }),
            .preflight = "HTTP/1.1 204 No Content\r\n" ++ cors ++ "Content-Length: 0\r\nConnection: close\r\n\r\n",
        };
    }

    /// The reply to a plain HTTP request, or null to leave it to the WebSocket handshake.
    pub fn respond(self: *const Responses, request: []const u8) ?[]const u8 {
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
        const request_line = request[0..line_end];
        if (std.mem.startsWith(u8, request_line, "OPTIONS ")) return self.preflight;
        if (!std.mem.startsWith(u8, request_line, "GET ")) return null;
        var headers = std.mem.splitSequence(u8, request[line_end + 2 ..], "\r\n");
        while (headers.next()) |header| {
            const colon = std.mem.indexOfScalar(u8, header, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, header[0..colon], " "), "accept")) continue;
            if (std.ascii.indexOfIgnoreCase(header[colon + 1 ..], media_type) != null) return self.document;
        }
        return null;
    }
};

const cors = "Access-Control-Allow-Origin: *\r\n" ++
    "Access-Control-Allow-Headers: *\r\n" ++
    "Access-Control-Allow-Methods: GET, OPTIONS\r\n";

fn renderDocument(arena: std.mem.Allocator, settings: config.Config) error{OutOfMemory}![]const u8 {
    const info = settings.info;
    const limits = settings.limits;
    const document = .{
        .name = info.name,
        .description = info.description,
        .banner = info.banner,
        .icon = info.icon,
        .pubkey = info.pubkey,
        .contact = info.contact,
        .supported_nips = supported_nips,
        .software = software,
        .version = root.version,
        .limitation = .{
            .max_message_length = limits.max_message_size,
            .max_subscriptions = limits.max_subscriptions,
            .max_limit = limits.max_limit,
            .max_subid_length = limits.max_subid_length,
            .max_event_tags = limits.max_event_tags,
            .max_content_length = limits.max_content_length,
            .default_limit = limits.default_limit,
            .created_at_lower_limit = limits.created_at_lower_limit_s,
            .created_at_upper_limit = limits.created_at_upper_limit_s,
            .min_pow_difficulty = 0,
            .auth_required = false,
            .payment_required = false,
            .restricted_writes = false,
        },
        .posting_policy = info.posting_policy,
        .privacy_policy = info.privacy_policy,
        .terms_of_service = info.terms_of_service,
        .relay_countries = info.relay_countries,
        .language_tags = info.language_tags,
    };
    return std.json.Stringify.valueAlloc(arena, document, .{ .emit_null_optional_fields = false });
}

const testing = std.testing;

test "supported_nips is exactly the supported rows of nips.md" {
    var expected: std.ArrayList(u16) = .empty;
    defer expected.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, nips_table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| [")) continue;
        if (std.mem.indexOf(u8, line, "| supported |") == null) continue;
        const close = std.mem.indexOfScalar(u8, line, ']').?;
        try expected.append(testing.allocator, try std.fmt.parseInt(u16, line[3..close], 10));
    }
    try testing.expect(expected.items.len != 0);
    try testing.expectEqualSlices(u16, expected.items, supported_nips);
}

fn renderDefaults(arena: std.mem.Allocator) !std.json.Value {
    const responses = try Responses.render(arena, .{ .info = .{ .name = "test relay", .language_tags = &.{"en"} } });
    const body_start = std.mem.indexOf(u8, responses.document, "\r\n\r\n").? + 4;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, responses.document[body_start..], .{});
}

test "the document carries the configuration, the limits and the supported NIPs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const document = (try renderDefaults(arena_state.allocator())).object;

    try testing.expectEqualStrings("test relay", document.get("name").?.string);
    try testing.expect(document.get("description") == null);
    try testing.expectEqualStrings(software, document.get("software").?.string);
    try testing.expectEqualStrings("en", document.get("language_tags").?.array.items[0].string);

    const nips = document.get("supported_nips").?.array.items;
    try testing.expectEqual(supported_nips.len, nips.len);
    for (supported_nips, nips) |want, got| try testing.expectEqual(@as(i64, want), got.integer);

    const limitation = document.get("limitation").?.object;
    try testing.expectEqual(@as(i64, 131072), limitation.get("max_message_length").?.integer);
    try testing.expectEqual(@as(i64, 500), limitation.get("default_limit").?.integer);
    try testing.expect(limitation.get("created_at_lower_limit") == null);
}

test "only a GET asking for nostr+json, or a preflight, is answered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const responses = try Responses.render(arena_state.allocator(), .{});

    const asking = "GET / HTTP/1.1\r\nHost: x\r\nACCEPT: application/nostr+json\r\n\r\n";
    try testing.expect(std.mem.startsWith(u8, responses.respond(asking).?, "HTTP/1.1 200 OK\r\nContent-Type: application/nostr+json\r\n"));
    try testing.expect(std.mem.indexOf(u8, responses.respond(asking).?, "Access-Control-Allow-Origin: *\r\n") != null);
    try testing.expect(std.mem.startsWith(u8, responses.respond("OPTIONS / HTTP/1.1\r\n\r\n").?, "HTTP/1.1 204"));
    try testing.expect(responses.respond("GET / HTTP/1.1\r\nAccept: text/html\r\n\r\n") == null);
    try testing.expect(responses.respond("POST / HTTP/1.1\r\nAccept: application/nostr+json\r\n\r\n") == null);
    try testing.expect(responses.respond("garbage") == null);
}
