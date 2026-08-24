//! NIP-01 as docs/protocol.md states it, checked over a real WebSocket
//! connection to a relay with an in-memory store.
//!
//! One test per rule, named after the rule. These are written from the
//! document rather than from the implementation: a test derived from the code
//! agrees with the code by construction, which is not the property worth
//! having.

const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;

const testing = std.testing;

fn expectOk(client: *Client, accepted: bool, message_prefix: []const u8) !void {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expectEqual(accepted, answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, message_prefix));
}

fn expectEventFor(client: *Client, subscription_id: []const u8) !nostr.event.Event {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("EVENT", answer.array.items[0].string);
    try testing.expectEqualStrings(subscription_id, answer.array.items[1].string);
    return nostr.event.fromValueLeaky(client.allocator(), answer.array.items[2]);
}

fn expectEose(client: *Client, subscription_id: []const u8) !void {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("EOSE", answer.array.items[0].string);
    try testing.expectEqualStrings(subscription_id, answer.array.items[1].string);
}

test "every stored event precedes EOSE, and a live event follows it" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(1);
    defer author.deinit();

    var publisher = try Client.connect(relay);
    defer publisher.close();
    var subscriber = try Client.connect(relay);
    defer subscriber.close();

    const stored = try author.event(publisher.allocator(), harness.event_time, 1, &.{}, "stored");
    try publisher.sendEvent(stored);
    try expectOk(&publisher, true, "");

    try subscriber.send("[\"REQ\",\"s\",{}]");
    const replayed = try expectEventFor(&subscriber, "s");
    try testing.expectEqualStrings("stored", replayed.content);
    try expectEose(&subscriber, "s");

    const live = try author.event(publisher.allocator(), harness.event_time + 1, 1, &.{}, "live");
    try publisher.sendEvent(live);
    try expectOk(&publisher, true, "");

    const delivered = try expectEventFor(&subscriber, "s");
    try testing.expectEqualStrings("live", delivered.content);
}

test "stored events are streamed newest first" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(2);
    defer author.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    // Published oldest first, so that insertion order cannot pass for the
    // answer.
    for ([_][]const u8{ "oldest", "middle", "newest" }, 0..) |content, offset| {
        const event = try author.event(
            client.allocator(),
            harness.event_time + @as(i64, @intCast(offset)),
            1,
            &.{},
            content,
        );
        try client.sendEvent(event);
        try expectOk(&client, true, "");
    }

    try client.send("[\"REQ\",\"s\",{}]");
    for ([_][]const u8{ "newest", "middle", "oldest" }) |expected| {
        const event = try expectEventFor(&client, "s");
        try testing.expectEqualStrings(expected, event.content);
    }
    try expectEose(&client, "s");
}

test "one REQ naming several limits is bounded by the largest across the merge" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(3);
    defer author.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    // Two kinds, two events each, published oldest first.
    for ([_]u16{ 1, 7, 1, 7 }, 0..) |kind, offset| {
        const event = try author.event(
            client.allocator(),
            harness.event_time + @as(i64, @intCast(offset)),
            kind,
            &.{},
            "x",
        );
        try client.sendEvent(event);
        try expectOk(&client, true, "");
    }

    // The bound is three, not one, not two, and not four: the largest limit
    // any filter asked for, applied across the merged result.
    try client.send("[\"REQ\",\"s\",{\"kinds\":[1],\"limit\":1},{\"kinds\":[7],\"limit\":3}]");
    var received: usize = 0;
    while (true) {
        const answer = try client.receiveJson();
        if (std.mem.eql(u8, answer.array.items[0].string, "EOSE")) break;
        try testing.expectEqualStrings("EVENT", answer.array.items[0].string);
        received += 1;
    }
    try testing.expectEqual(@as(usize, 3), received);
}

test "an event whose id does not match its content is rejected as invalid" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(4);
    defer author.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    var event = try author.event(client.allocator(), harness.event_time, 1, &.{}, "tampered");
    event.id[0] ^= 0xff;
    try client.sendEvent(event);
    try expectOk(&client, false, "invalid:");
}

test "an event with a valid id and an invalid signature is rejected as invalid" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(5);
    defer author.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    var event = try author.event(client.allocator(), harness.event_time, 1, &.{}, "forged");
    event.sig[0] ^= 0xff;
    try client.sendEvent(event);
    try expectOk(&client, false, "invalid:");

    // And it was not stored: a rejected event must not come back.
    try client.send("[\"REQ\",\"s\",{}]");
    try expectEose(&client, "s");
}

test "an event the relay already holds is accepted again with duplicate" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(6);
    defer author.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    const event = try author.event(client.allocator(), harness.event_time, 1, &.{}, "twice");
    try client.sendEvent(event);
    try expectOk(&client, true, "");

    try client.sendEvent(event);
    // True, not false: the client's event is on the relay, which is what it
    // asked for (docs/protocol.md).
    try expectOk(&client, true, "duplicate:");
}

test "filters are OR-ed with each other and AND-ed within" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var wanted = try harness.Author.init(7);
    defer wanted.deinit();
    var other = try harness.Author.init(8);
    defer other.deinit();

    var client = try Client.connect(relay);
    defer client.close();

    try client.sendEvent(try wanted.event(client.allocator(), harness.event_time, 1, &.{}, "wanted kind and author"));
    try expectOk(&client, true, "");
    try client.sendEvent(try other.event(client.allocator(), harness.event_time + 1, 1, &.{}, "wrong author"));
    try expectOk(&client, true, "");
    try client.sendEvent(try wanted.event(client.allocator(), harness.event_time + 2, 3, &.{}, "wrong kind"));
    try expectOk(&client, true, "");

    const request = try std.fmt.allocPrint(
        client.allocator(),
        "[\"REQ\",\"s\",{{\"kinds\":[1],\"authors\":[\"{s}\"]}},{{\"kinds\":[7]}}]",
        .{wanted.pubkeyHex()},
    );
    try client.send(request);

    const matched = try expectEventFor(&client, "s");
    try testing.expectEqualStrings("wanted kind and author", matched.content);
    try expectEose(&client, "s");
}

test "a closed subscription receives nothing further" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();

    var author = try harness.Author.init(9);
    defer author.deinit();

    var publisher = try Client.connect(relay);
    defer publisher.close();
    var subscriber = try Client.connect(relay);
    defer subscriber.close();

    try subscriber.send("[\"REQ\",\"s\",{}]");
    try expectEose(&subscriber, "s");
    try subscriber.send("[\"CLOSE\",\"s\"]");

    try publisher.sendEvent(try author.event(publisher.allocator(), harness.event_time, 1, &.{}, "after close"));
    try expectOk(&publisher, true, "");

    try subscriber.expectSilence(300);
}
