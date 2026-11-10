const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;
const t0 = harness.event_time;

fn publish(client: *Client, event: nostr.event.Event, accepted: bool, message_prefix: []const u8) !void {
    try client.sendEvent(event);
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expectEqual(accepted, answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, message_prefix));
}

fn stored(client: *Client, filter_json: []const u8) ![]nostr.event.Event {
    const request = try std.fmt.allocPrint(client.allocator(), "[\"REQ\",\"q\",{s}]", .{filter_json});
    try client.send(request);
    var events: std.ArrayList(nostr.event.Event) = .empty;
    while (true) {
        const answer = try client.receiveJson();
        if (std.mem.eql(u8, answer.array.items[0].string, "EOSE")) break;
        try events.append(client.allocator(), try nostr.event.fromValueLeaky(client.allocator(), answer.array.items[2]));
    }
    try client.send("[\"CLOSE\",\"q\"]");
    return events.items;
}

fn hex(client: *Client, bytes: [32]u8) ![]const u8 {
    return client.allocator().dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

test "a deletion request removes its author's event and is itself stored" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(40);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const note = try author.event(client.allocator(), t0, 1, &.{}, "regret");
    try publish(&client, note, true, "");
    const request = try author.event(client.allocator(), t0 + 1, 5, &.{&.{ "e", try hex(&client, note.id) }}, "");
    try publish(&client, request, true, "");

    try testing.expectEqual(@as(usize, 0), (try stored(&client, "{\"kinds\":[1]}")).len);
    const deletions = try stored(&client, "{\"kinds\":[5]}");
    try testing.expectEqual(@as(usize, 1), deletions.len);
    try testing.expectEqualSlices(u8, &request.id, &deletions[0].id);
}

test "a deletion request naming another author's event is ignored" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var alice = try Author.init(41);
    defer alice.deinit();
    var mallory = try Author.init(42);
    defer mallory.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const note = try alice.event(client.allocator(), t0, 1, &.{}, "mine");
    try publish(&client, note, true, "");
    try publish(&client, try mallory.event(client.allocator(), t0 + 1, 5, &.{&.{ "e", try hex(&client, note.id) }}, ""), true, "");

    try testing.expectEqual(@as(usize, 1), (try stored(&client, "{\"kinds\":[1]}")).len);
    try publish(&client, note, true, "duplicate:");
}

test "a deleted event sent again is refused with blocked" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(43);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const note = try author.event(client.allocator(), t0, 1, &.{}, "gone");
    try publish(&client, note, true, "");
    try publish(&client, try author.event(client.allocator(), t0 + 1, 5, &.{&.{ "e", try hex(&client, note.id) }}, ""), true, "");

    try publish(&client, note, false, "blocked:");
    try testing.expectEqual(@as(usize, 0), (try stored(&client, "{\"kinds\":[1]}")).len);
}

test "an a tag deletes the versions of an address up to the request's created_at" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(44);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const slot: []const nostr.event.Tag = &.{&.{ "d", "post" }};
    const older = try author.event(client.allocator(), t0, 30023, slot, "v1");
    try publish(&client, older, true, "");

    const address = try std.fmt.allocPrint(client.allocator(), "30023:{s}:post", .{try hex(&client, author.keypair.public_key)});
    try publish(&client, try author.event(client.allocator(), t0 + 10, 5, &.{&.{ "a", address }}, ""), true, "");
    try testing.expectEqual(@as(usize, 0), (try stored(&client, "{\"kinds\":[30023]}")).len);

    try publish(&client, try author.event(client.allocator(), t0 + 5, 30023, slot, "v2, still deleted"), false, "blocked:");
    try publish(&client, try author.event(client.allocator(), t0 + 11, 30023, slot, "v3"), true, "");
    const survivors = try stored(&client, "{\"kinds\":[30023]}");
    try testing.expectEqual(@as(usize, 1), survivors.len);
    try testing.expectEqualStrings("v3", survivors[0].content);
}

test "deleting a deletion request has no effect" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(45);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const note = try author.event(client.allocator(), t0, 1, &.{}, "gone");
    try publish(&client, note, true, "");
    const first = try author.event(client.allocator(), t0 + 1, 5, &.{&.{ "e", try hex(&client, note.id) }}, "");
    try publish(&client, first, true, "");
    try publish(&client, try author.event(client.allocator(), t0 + 2, 5, &.{&.{ "e", try hex(&client, first.id) }}, ""), true, "");

    try testing.expectEqual(@as(usize, 2), (try stored(&client, "{\"kinds\":[5]}")).len);
    try publish(&client, note, false, "blocked:");
}
