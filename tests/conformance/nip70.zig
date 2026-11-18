const std = @import("std");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;
const t0 = harness.event_time;

fn expectOk(client: *Client, id: [32]u8, accepted: bool, prefix: []const u8) !void {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(id, .lower), answer.array.items[1].string);
    try testing.expectEqual(accepted, answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, prefix));
}

fn authenticate(client: *Client, relay: *Relay, author: Author, challenge: []const u8) !void {
    const auth = try author.authEvent(client.allocator(), relay.io(), challenge, Client.relay_url);
    try client.sendAuth(auth);
    try expectOk(client, auth.id, true, "");
}

test "a protected event from an unauthenticated client is refused with auth-required, after a challenge" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(70);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const protected = try author.event(client.allocator(), t0, 1, &.{&.{"-"}}, "mine only");
    try client.sendEvent(protected);
    const challenge = try client.receiveJson();
    try testing.expectEqualStrings("AUTH", challenge.array.items[0].string);
    try expectOk(&client, protected.id, false, "auth-required:");

    try authenticate(&client, relay, author, challenge.array.items[1].string);
    try client.sendEvent(protected);
    try expectOk(&client, protected.id, true, "");
}

test "a protected event from a client authenticated as someone else is refused with restricted" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(71);
    defer author.deinit();
    var other = try Author.init(72);
    defer other.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const protected = try author.event(client.allocator(), t0, 1, &.{&.{"-"}}, "not yours");
    try client.sendEvent(protected);
    const challenge = (try client.receiveJson()).array.items[1].string;
    try expectOk(&client, protected.id, false, "auth-required:");

    try authenticate(&client, relay, other, challenge);
    try client.sendEvent(protected);
    try expectOk(&client, protected.id, false, "restricted:");
}

test "an unprotected event needs no authentication" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(73);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const note = try author.event(client.allocator(), t0, 1, &.{&.{ "t", "-" }}, "anyone may relay this");
    try client.sendEvent(note);
    try expectOk(&client, note.id, true, "");
}
