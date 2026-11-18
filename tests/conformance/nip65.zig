const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;
const t0 = harness.event_time;
const relay_list: u16 = 10002;

fn publish(client: *Client, event: nostr.event.Event) !void {
    try client.sendEvent(event);
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expect(answer.array.items[2].bool);
}

fn stored(client: *Client, filter_json: []const u8) ![]nostr.event.Event {
    try client.send(try std.fmt.allocPrint(client.allocator(), "[\"REQ\",\"q\",{s}]", .{filter_json}));
    var events: std.ArrayList(nostr.event.Event) = .empty;
    while (true) {
        const answer = try client.receiveJson();
        if (std.mem.eql(u8, answer.array.items[0].string, "EOSE")) break;
        try events.append(client.allocator(), try nostr.event.fromValueLeaky(client.allocator(), answer.array.items[2]));
    }
    try client.send("[\"CLOSE\",\"q\"]");
    return events.items;
}

test "a newer relay list replaces the author's previous one, its r tags and markers intact" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(90);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const arena = client.allocator();

    try publish(&client, try author.event(arena, t0, relay_list, &.{&.{ "r", "wss://old.example" }}, ""));
    const current = try author.event(arena, t0 + 1, relay_list, &.{
        &.{ "r", "wss://both.example" },
        &.{ "r", "wss://inbox.example", "read" },
        &.{ "r", "wss://outbox.example", "write" },
    }, "");
    try publish(&client, current);

    const filter = try std.fmt.allocPrint(arena, "{{\"kinds\":[10002],\"authors\":[\"{s}\"]}}", .{&author.pubkeyHex()});
    const lists = try stored(&client, filter);
    try testing.expectEqual(@as(usize, 1), lists.len);
    try testing.expectEqualSlices(u8, &current.id, &lists[0].id);
    try testing.expectEqual(@as(usize, 3), lists[0].tags.len);
    try testing.expectEqualStrings("read", lists[0].tags[1][2]);
    try testing.expectEqualStrings("write", lists[0].tags[2][2]);
}

test "relay lists are found by a relay they name" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var alice = try Author.init(91);
    defer alice.deinit();
    var bob = try Author.init(92);
    defer bob.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const arena = client.allocator();

    try publish(&client, try alice.event(arena, t0, relay_list, &.{&.{ "r", "wss://shared.example" }}, ""));
    try publish(&client, try bob.event(arena, t0, relay_list, &.{&.{ "r", "wss://elsewhere.example" }}, ""));

    const lists = try stored(&client, "{\"kinds\":[10002],\"#r\":[\"wss://shared.example\"]}");
    try testing.expectEqual(@as(usize, 1), lists.len);
    try testing.expectEqualSlices(u8, &alice.keypair.public_key, &lists[0].pubkey);
}
