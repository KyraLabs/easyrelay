# Architecture Decision Records

Each record captures one decision, the context that forced it, and what it costs. Records are
immutable in intent: when a decision changes, the old record is marked `Superseded by NNNN` and
a new one is written. A record is amended in place only to correct a factual error or to record
the outcome of a validation that the record itself scheduled.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-language-and-toolchain.md) | Zig 0.16.0 with a pinned toolchain | Accepted |
| [0002](0002-build-on-zig-nostr.md) | Build on `zig-nostr/nostr` | Accepted |
| [0003](0003-storage-engine-lmdb.md) | LMDB with custom indexes, not SQL | Accepted |
| [0004](0004-websocket-transport.md) | `websocket.zig` as the transport | Accepted |
| [0005](0005-concurrency-model.md) | Thread pool now, evented runtime in Phase 6 | Accepted |
| [0006](0006-cryptography.md) | BIP-340 via `libsecp256k1`, never `std.crypto` | Accepted |
| [0007](0007-configuration-format.md) | Configuration file format | Proposed |
| [0008](0008-store-abstraction-boundary.md) | A first-party `Store` interface as an isolation boundary | Accepted |
| [0009](0009-deployment-experience.md) | Zero-configuration defaults, TLS via a bundled proxy | Accepted |

Use [0000-template.md](0000-template.md) for new records.
