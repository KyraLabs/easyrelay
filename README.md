# easyrelay

A [Nostr](https://github.com/nostr-protocol/nips) relay written in [Zig](https://ziglang.org).

**Status: pre-alpha.** There is no working relay yet. This repository currently contains the
design documentation only. See the [roadmap](docs/roadmap.md) for what is being built and in
which order.

## What it is

easyrelay is a relay built for real deployment rather than demonstration: a single static
binary, an embedded LMDB store with no external database to operate, predictable memory
behaviour, and full coverage of the NIPs a serious relay is expected to speak — up to and
including NIP-77 set reconciliation.

It is built on top of [`zig-nostr/nostr`](https://github.com/zig-nostr/nostr), which supplies
the protocol primitives (event model, canonical serialization, BIP-340 Schnorr verification via
a vendored `libsecp256k1`, filter matching) and a zero-copy LMDB event store. easyrelay adds
what a relay needs on top of a protocol library: the WebSocket server, the subscription engine,
the admission policy layer, and the operational surface.

## Documentation

Start here:

| Document | Contents |
| --- | --- |
| [Overview](docs/overview.md) | Vision, goals, non-goals, who this is for |
| [Roadmap](docs/roadmap.md) | Implementation phases with exit criteria |
| [Architecture](docs/architecture.md) | Layers, threading model, data flow, repository layout |

Reference:

| Document | Contents |
| --- | --- |
| [Protocol](docs/protocol.md) | Wire behaviour: messages, filters, kind semantics, error prefixes |
| [Storage](docs/storage.md) | Data model, indexes, retention, deletion, expiration |
| [NIP coverage](docs/nips.md) | Per-NIP status and the phase that delivers it |
| [Configuration](docs/configuration.md) | Configuration reference |
| [Operations](docs/operations.md) | Deployment, TLS, backup, metrics, tuning |
| [Testing](docs/testing.md) | Test strategy, conformance, fuzzing, benchmarks |
| [Development](docs/development.md) | Toolchain setup and build commands |
| [Decisions](docs/adr/) | Architecture Decision Records |

`docs/research/` holds background research written before the project started. It is dated,
written in Spanish, and is not maintained as project documentation.

## Requirements

- Zig `0.16.0` (pinned in `.zigversion`)

No system packages are required. `libsecp256k1` and LMDB are vendored and compiled from source
by the dependency graph, and Zig ships its own C compiler.

## License

MIT. See [LICENSE](LICENSE).
