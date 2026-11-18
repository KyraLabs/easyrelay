const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;

fn expectOk(client: *Client, id: [32]u8, accepted: bool, prefix: []const u8) !void {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(id, .lower), answer.array.items[1].string);
    try testing.expectEqual(accepted, answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, prefix));
}

fn storedCount(client: *Client) !usize {
    try client.send("[\"REQ\",\"q\",{}]");
    var count: usize = 0;
    while (true) {
        const answer = try client.receiveJson();
        if (std.mem.eql(u8, answer.array.items[0].string, "EOSE")) break;
        count += 1;
    }
    try client.send("[\"CLOSE\",\"q\"]");
    return count;
}

fn expiringAt(client: *Client, author: Author, now: i64, at: i64) !nostr.event.Event {
    const arena = client.allocator();
    const tags = try arena.alloc(nostr.event.Tag, 1);
    tags[0] = try arena.dupe([]const u8, &.{ "expiration", try std.fmt.allocPrint(arena, "{d}", .{at}) });
    return author.event(arena, now, 1, tags, "short-lived");
}

test "an event whose expiration has already passed is refused" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(80);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const now = std.Io.Timestamp.now(relay.io(), .real).toSeconds();

    const expired = try expiringAt(&client, author, now - 10, now - 1);
    try client.sendEvent(expired);
    try expectOk(&client, expired.id, false, "invalid:");
    try testing.expectEqual(@as(usize, 0), try storedCount(&client));
}

test "an event is served until its expiration and not after" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(81);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const now = std.Io.Timestamp.now(relay.io(), .real).toSeconds();

    const brief = try expiringAt(&client, author, now, now + 1);
    try client.sendEvent(brief);
    try expectOk(&client, brief.id, true, "");
    try testing.expectEqual(@as(usize, 1), try storedCount(&client));

    try std.Io.sleep(relay.io(), .fromMilliseconds(2100), .awake);
    try testing.expectEqual(@as(usize, 0), try storedCount(&client));
}

test "an expiration tag that is not a timestamp is refused" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(82);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const arena = client.allocator();
    const tags = try arena.alloc(nostr.event.Tag, 1);
    tags[0] = try arena.dupe([]const u8, &.{ "expiration", "tomorrow" });
    const malformed = try author.event(arena, harness.event_time, 1, tags, "");
    try client.sendEvent(malformed);
    try expectOk(&client, malformed.id, false, "invalid:");
}
