const std = @import("std");
const nostr = @import("nostr");

const harness = @import("harness.zig");
const Client = harness.Client;
const Relay = harness.Relay;
const Author = harness.Author;

const testing = std.testing;
const t0 = harness.event_time;

fn expectChallenge(client: *Client) ![]const u8 {
    const message = try client.receiveJson();
    try testing.expectEqualStrings("AUTH", message.array.items[0].string);
    try testing.expectEqual(@as(usize, 2), message.array.items.len);
    return message.array.items[1].string;
}

fn expectOk(client: *Client, id: [32]u8, accepted: bool, prefix: []const u8) !void {
    const answer = try client.receiveJson();
    try testing.expectEqualStrings("OK", answer.array.items[0].string);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(id, .lower), answer.array.items[1].string);
    try testing.expectEqual(accepted, answer.array.items[2].bool);
    try testing.expect(std.mem.startsWith(u8, answer.array.items[3].string, prefix));
}

test "a relay requiring authentication sends its challenge when the connection opens" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_write = true } });
    defer relay.stop();
    var client = try Client.connect(relay);
    defer client.close();

    try testing.expect((try expectChallenge(&client)).len >= 16);
}

test "an AUTH event signing the challenge and naming the relay is answered OK true" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_write = true } });
    defer relay.stop();
    var author = try Author.init(60);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();

    const challenge = try expectChallenge(&client);
    const auth = try author.authEvent(client.allocator(), relay.io(), challenge, Client.relay_url);
    try client.sendAuth(auth);
    try expectOk(&client, auth.id, true, "");

    const note = try author.event(client.allocator(), t0, 1, &.{}, "after auth");
    try client.sendEvent(note);
    try expectOk(&client, note.id, true, "");
}

test "an event before authentication is refused with auth-required" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_write = true } });
    defer relay.stop();
    var author = try Author.init(61);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    _ = try expectChallenge(&client);

    const note = try author.event(client.allocator(), t0, 1, &.{}, "too early");
    try client.sendEvent(note);
    try expectOk(&client, note.id, false, "auth-required:");
}

test "a subscription before authentication is closed with auth-required" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_read = true } });
    defer relay.stop();
    var client = try Client.connect(relay);
    defer client.close();
    _ = try expectChallenge(&client);

    try client.send("[\"REQ\",\"s\",{}]");
    const closed = try client.receiveJson();
    try testing.expectEqualStrings("CLOSED", closed.array.items[0].string);
    try testing.expectEqualStrings("s", closed.array.items[1].string);
    try testing.expect(std.mem.startsWith(u8, closed.array.items[2].string, "auth-required:"));
}

test "an AUTH event with the wrong challenge, relay, kind or age is refused" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_write = true } });
    defer relay.stop();
    var author = try Author.init(62);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const challenge = try expectChallenge(&client);
    const arena = client.allocator();
    const now = std.Io.Timestamp.now(relay.io(), .real).toSeconds();

    const wrong_challenge = try author.authEvent(arena, relay.io(), "not-the-challenge", Client.relay_url);
    const wrong_relay = try author.authEvent(arena, relay.io(), challenge, "wss://another.example");
    const wrong_kind = try author.event(arena, now, 1, &.{ &.{ "relay", Client.relay_url }, &.{ "challenge", challenge } }, "");
    const stale = try author.event(arena, now - 3600, 22242, &.{ &.{ "relay", Client.relay_url }, &.{ "challenge", challenge } }, "");
    for ([_]nostr.event.Event{ wrong_challenge, wrong_relay, wrong_kind, stale }) |attempt| {
        try client.sendAuth(attempt);
        try expectOk(&client, attempt.id, false, "invalid:");
    }

    const note = try author.event(arena, t0, 1, &.{}, "still unauthenticated");
    try client.sendEvent(note);
    try expectOk(&client, note.id, false, "auth-required:");
}

test "an AUTH event with a bad signature is refused" {
    const relay = try Relay.startWith(testing.allocator, .{ .policy = .{ .auth_required_for_write = true } });
    defer relay.stop();
    var author = try Author.init(63);
    defer author.deinit();
    var client = try Client.connect(relay);
    defer client.close();
    const challenge = try expectChallenge(&client);

    var forged = try author.authEvent(client.allocator(), relay.io(), challenge, Client.relay_url);
    forged.sig[0] ^= 1;
    try client.sendAuth(forged);
    try expectOk(&client, forged.id, false, "invalid:");
}

test "a kind 22242 event sent with EVENT is refused and never broadcast" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var author = try Author.init(64);
    defer author.deinit();
    var listener = try Client.connect(relay);
    defer listener.close();
    try listener.send("[\"REQ\",\"all\",{}]");
    try testing.expectEqualStrings("EOSE", (try listener.receiveJson()).array.items[0].string);

    var client = try Client.connect(relay);
    defer client.close();
    const auth = try author.authEvent(client.allocator(), relay.io(), "anything", Client.relay_url);
    try client.sendEvent(auth);
    try expectOk(&client, auth.id, false, "invalid:");
    try listener.expectSilence(200);
}

test "a relay that requires nothing sends no challenge on connect" {
    const relay = try Relay.start(testing.allocator, .{});
    defer relay.stop();
    var client = try Client.connect(relay);
    defer client.close();
    try client.expectSilence(200);
}
