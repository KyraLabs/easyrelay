const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;
const t0 = harness.event_time;

fn publish(client: *Client, event: nostr.event.Event, message_prefix: []const u8) !void {
    try client.sendEvent(event);
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expect(answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, message_prefix));
}

fn stored(client: *Client, filter_json: []const u8) ![]nostr.event.Event {
    const request = try std.fmt.allocPrint(client.allocator(), "[\"REQ\",\"q\",{s}]", .{filter_json});
    try client.send(request);
    var events: std.ArrayList(nostr.event.Event) = .empty;
    while (true) {
        const answer = try client.receiveJson();
        const message_type = answer.array.items[0].string;
        if (std.mem.eql(u8, message_type, "EOSE")) break;
        try testing.expectEqualStrings("EVENT", message_type);
        try events.append(client.allocator(), try nostr.event.fromValueLeaky(client.allocator(), answer.array.items[2]));
    }
    try client.send("[\"CLOSE\",\"q\"]");
    return events.items;
}

test "a newer replaceable event replaces the stored one" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(20);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    try publish(&client, try author.event(client.allocator(), t0, 0, &.{}, "old"), "");
    try publish(&client, try author.event(client.allocator(), t0 + 1, 0, &.{}, "new"), "");

    const events = try stored(&client, "{\"kinds\":[0]}");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("new", events[0].content);
}

test "an older replaceable event is answered with duplicate and not stored" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(21);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    try publish(&client, try author.event(client.allocator(), t0 + 1, 10002, &.{}, "new"), "");
    try publish(&client, try author.event(client.allocator(), t0, 10002, &.{}, "old"), "duplicate:");

    const events = try stored(&client, "{\"kinds\":[10002]}");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("new", events[0].content);
}

test "replaceable events sharing a created_at keep the lexically smaller id" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(22);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const a = try author.event(client.allocator(), t0, 3, &.{}, "a");
    const b = try author.event(client.allocator(), t0, 3, &.{}, "b");
    const smaller, const larger = if (std.mem.order(u8, &a.id, &b.id) == .lt) .{ a, b } else .{ b, a };

    try publish(&client, larger, "");
    try publish(&client, smaller, "");
    try publish(&client, larger, "duplicate:");

    const events = try stored(&client, "{\"kinds\":[3]}");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualSlices(u8, &smaller.id, &events[0].id);
}

test "a replaceable event does not replace another author's" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var alice = try Author.init(23);
    defer alice.deinit();
    var bob = try Author.init(24);
    defer bob.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    try publish(&client, try alice.event(client.allocator(), t0, 0, &.{}, "alice"), "");
    try publish(&client, try bob.event(client.allocator(), t0 + 1, 0, &.{}, "bob"), "");

    try testing.expectEqual(@as(usize, 2), (try stored(&client, "{\"kinds\":[0]}")).len);
}

test "an addressable event replaces only the event at its d coordinate" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(25);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const slot_a: []const nostr.event.Tag = &.{&.{ "d", "a" }};
    const slot_b: []const nostr.event.Tag = &.{&.{ "d", "b" }};
    try publish(&client, try author.event(client.allocator(), t0, 30023, slot_a, "a1"), "");
    try publish(&client, try author.event(client.allocator(), t0, 30023, slot_b, "b1"), "");
    try publish(&client, try author.event(client.allocator(), t0 + 1, 30023, slot_a, "a2"), "");

    const events = try stored(&client, "{\"kinds\":[30023]}");
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("a2", events[0].content);
    try testing.expectEqualStrings("b1", events[1].content);
}

test "an absent d tag, a bare d tag and an empty d value address the same slot" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(26);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    try publish(&client, try author.event(client.allocator(), t0, 30000, &.{}, "absent"), "");
    try publish(&client, try author.event(client.allocator(), t0 + 1, 30000, &.{&.{"d"}}, "bare"), "");
    try publish(&client, try author.event(client.allocator(), t0 + 2, 30000, &.{&.{ "d", "" }}, "empty"), "");

    const events = try stored(&client, "{\"kinds\":[30000]}");
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("empty", events[0].content);
}

test "an ephemeral event is fanned out and never stored" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(27);
    defer author.deinit();
    var publisher = try Client.connect(relay);
    defer publisher.close();
    var subscriber = try Client.connect(relay);
    defer subscriber.close();

    try subscriber.send("[\"REQ\",\"live\",{\"kinds\":[20001]}]");
    _ = try subscriber.receiveJson();

    try publish(&publisher, try author.event(publisher.allocator(), t0, 20001, &.{}, "fleeting"), "");

    const live = try subscriber.receiveJson();
    try testing.expectEqualStrings("EVENT", live.array.items[0].string);
    try testing.expectEqualStrings("live", live.array.items[1].string);

    try testing.expectEqual(@as(usize, 0), (try stored(&publisher, "{\"kinds\":[20001]}")).len);
}
