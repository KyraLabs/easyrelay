//! easyrelay — a Nostr relay.
//!
//! This module is the relay itself. `src/main.zig` is only the command-line
//! front end, so that the relay can also be embedded.
//!
//! Nothing is implemented yet. See docs/roadmap.md for the order of work and
//! docs/architecture.md for where each piece is meant to live.

const std = @import("std");

/// Semantic version of the relay, reported by `easyrelay --version` and by the
/// NIP-11 relay information document once that exists.
pub const version = "0.0.0-dev";

test "version is a non-empty semantic version" {
    try std.testing.expect(version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, version, '.') != null);
}
