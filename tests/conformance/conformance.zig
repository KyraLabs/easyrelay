//! The conformance suite: docs/protocol.md as executable checks.
//!
//! One file per document section as the suite grows; `harness.zig` holds what
//! they all need. Run by `zig build test` like everything else.

test {
    _ = @import("nip01.zig");
}
