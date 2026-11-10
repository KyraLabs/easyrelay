const std = @import("std");

pub const version = "0.0.0-dev";

pub const store = @import("storage/store.zig");

pub const memory = @import("storage/memory.zig");

pub const lmdb = @import("storage/lmdb.zig");

pub const record = @import("storage/record.zig");

pub const kind = @import("storage/kind.zig");

pub const index = @import("storage/index.zig");

pub const validation = @import("relay/validation.zig");

pub const filter = @import("relay/filter.zig");

pub const codec = @import("relay/codec.zig");

pub const session = @import("relay/session.zig");

pub const subscriptions = @import("relay/subscriptions.zig");

pub const hub = @import("relay/hub.zig");

pub const writer = @import("relay/writer.zig");

pub const diagnostics = @import("relay/diagnostics.zig");

pub const server = @import("server/server.zig");

pub const config = @import("config.zig");

pub const nip11 = @import("relay/nip11.zig");

pub const frame = @import("transport/frame.zig");

pub const handshake = @import("transport/handshake.zig");

pub const socket = @import("transport/socket.zig");

pub const listener = @import("transport/listener.zig");

pub const client = @import("transport/client.zig");

test {
    _ = store;
    _ = memory;
    _ = lmdb;
    _ = record;
    _ = validation;
    _ = filter;
    _ = codec;
    _ = session;
    _ = subscriptions;
    _ = hub;
    _ = diagnostics;
    _ = server;
    _ = kind;
    _ = index;
    _ = writer;
    _ = config;
    _ = nip11;
    _ = frame;
    _ = handshake;
    _ = socket;
    _ = listener;
    _ = client;
}

test "version is a non-empty semantic version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}

test "the canonical serialization is NIP-01's, not a general JSON encoder's" {
    const nostr = @import("nostr");

    const canonical = try nostr.event.serializeCanonical(
        std.testing.allocator,
        [_]u8{0} ** 32,
        1700000000,
        1,
        &.{},
        "a\"b\\c\nd/é",
    );
    defer std.testing.allocator.free(canonical);

    try std.testing.expectEqualStrings(
        "[0,\"" ++ "00" ** 32 ++ "\",1700000000,1,[],\"a\\\"b\\\\c\\nd/é\"]",
        canonical,
    );
}

test "libsecp256k1 verifies a signed event and rejects a tampered id" {
    const nostr = @import("nostr");

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const keypair = try signer.keyPairFromSecretKey([_]u8{1} ** 32);
    const event = try nostr.event.create(
        std.testing.allocator,
        signer,
        keypair,
        1700000000,
        1,
        &.{},
        "hello",
        null,
    );
    try std.testing.expect(try nostr.event.verify(std.testing.allocator, signer, event));

    var tampered = event;
    tampered.id[0] ^= 0xff;
    try std.testing.expect(!try nostr.event.verify(std.testing.allocator, signer, tampered));
}

test "liblmdb commits durably and reads back after reopening" {
    const liblmdb = @import("lmdb");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, buffer[0..std.Io.Dir.max_path_bytes]);
    buffer[len] = 0;
    const path = buffer[0..len :0];

    {
        const env = try liblmdb.Environment.init(path, .{});
        defer env.deinit();

        const txn = try liblmdb.Transaction.init(env, .{ .mode = .ReadWrite });
        txn.set("k", "v") catch |err| {
            txn.abort();
            return err;
        };
        try txn.commit();
    }

    const env = try liblmdb.Environment.init(path, .{});
    defer env.deinit();

    const txn = try liblmdb.Transaction.init(env, .{ .mode = .ReadOnly });
    defer txn.abort();
    try std.testing.expectEqualStrings("v", (try txn.get("k")).?);
}
