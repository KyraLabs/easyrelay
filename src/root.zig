//! easyrelay — a Nostr relay.
//!
//! This module is the relay itself. `src/main.zig` is only the command-line
//! front end, so that the relay can also be embedded.
//!
//! Little is implemented yet. See docs/roadmap.md for the order of work and
//! docs/architecture.md for where each piece is meant to live.

const std = @import("std");

/// Semantic version of the relay, reported by `easyrelay --version` and by the
/// NIP-11 relay information document once that exists.
pub const version = "0.0.0-dev";

/// The storage layer. Everything above it reaches stored events through
/// `store.Store` and through nothing else; see
/// docs/adr/0008-store-abstraction-boundary.md.
pub const store = @import("storage/store.zig");

/// The in-memory backend: what Phase 1 runs on, and the oracle the property
/// tests hold the indexed backend to afterwards.
pub const memory = @import("storage/memory.zig");

/// Validation of inbound events, in the order docs/architecture.md fixes.
pub const validation = @import("relay/validation.zig");

/// Decoding the filters a `REQ` carries, with docs/protocol.md's strictness.
pub const filter = @import("relay/filter.zig");

/// The relay's half of the NIP-01 wire format.
pub const codec = @import("relay/codec.zig");

/// One client's conversation with the relay: what arrives, what is answered.
pub const session = @import("relay/session.zig");

/// The subscriptions one connection has open.
pub const subscriptions = @import("relay/subscriptions.zig");

/// Where an accepted event meets every subscription that wants it.
pub const hub = @import("relay/hub.zig");

/// How a failure explains itself to the client that caused it.
pub const diagnostics = @import("relay/diagnostics.zig");

/// The transport: sockets and frames, and nothing else.
pub const server = @import("server/server.zig");

test {
    _ = store;
    _ = memory;
    _ = validation;
    _ = filter;
    _ = codec;
    _ = session;
    _ = subscriptions;
    _ = hub;
    _ = diagnostics;
    _ = server;
}

test "version is a non-empty semantic version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}

// The dependencies are imported by the layers that need them rather than
// re-exported here; nothing from `zig-nostr`'s store crosses the `Store`
// boundary (docs/adr/0008-store-abstraction-boundary.md).
//
// What follows proves the dependency graph builds, links and runs. That is a
// real question and not a formality: `zig-nostr` compiles libsecp256k1 and
// LMDB from C source, and `websocket.zig`'s Zig 0.16 support is upstream-
// flagged as experimental.

test "the canonical serialization is NIP-01's, not a general JSON encoder's" {
    const nostr = @import("nostr");

    // Quote, backslash and line break are escaped; the forward slash and the
    // non-ASCII byte are not. A general-purpose JSON encoder escapes both of
    // the latter, which yields a different id and a relay no client accepts.
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

test "websocket.zig frames a text message" {
    const websocket = @import("websocket");

    const framed = websocket.frameText("hi");
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 2, 'h', 'i' }, &framed);
}
