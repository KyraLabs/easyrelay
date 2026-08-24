# easyrelay

A [Nostr](https://github.com/nostr-protocol/nips) relay written in [Zig](https://ziglang.org).

**Status: pre-alpha.** The relay works and is not ready to run for anyone else yet. It speaks
NIP-01 over WebSocket — publishing, subscriptions, live delivery, full event validation — and it
keeps everything in memory, so a restart loses it. Persistence and kind semantics are Phase 2;
the rate limits, authentication and distribution a public relay needs are Phase 3. See the
[roadmap](docs/roadmap.md) for what is being built and in which order.

## What it is

easyrelay has three goals, in this order. Where they conflict, the earlier one wins.

**It works.** Full NIP-01 conformance, correct handling of every kind class, and the NIPs a
serious relay is expected to speak — up to and including NIP-77 set reconciliation. A relay
that computes event ids from a non-canonical serialization is silently unusable no matter how
fast it is.

**It is fast.** An embedded LMDB store with hand-built indexes, zero-copy reads, and query cost
bounded by the requested page size rather than by how much history the relay holds. No garbage
collector, no unbounded queues, and limits on everything a client can grow.

**It is trivial to run.** Running `easyrelay` with no arguments and no configuration file gives
you a working relay. There is no database to create, no system package to install, no runtime
to provision. Getting a public relay onto the internet with TLS is one command. This is the
goal the name refers to, and it is treated as a feature with its own tests, not as a side
effect of shipping a static binary.

It is built on top of [`zig-nostr/nostr`](https://github.com/zig-nostr/nostr), which supplies
the protocol primitives (event model, canonical serialization, BIP-340 Schnorr verification via
a vendored `libsecp256k1`, filter matching) and a zero-copy LMDB event store. easyrelay adds
what a relay needs on top of a protocol library: the WebSocket server, the subscription engine,
the admission policy layer, and the operational surface.

## Quick start

> **Partly available.** Running the relay with no arguments works today. The data directory,
> the released binaries and the compose file below do not exist yet: they are what the Phase 2
> and Phase 3 exit criteria in the [roadmap](docs/roadmap.md) test for, written down here as a
> contract rather than an aspiration.

Run it:

```bash
easyrelay
```

That is the whole setup. The relay listens on `ws://127.0.0.1:7777`, creates its data directory
on first start, prints the URL it is serving, and is ready for a client. No configuration file
is required, and no argument is mandatory.

Put it on the internet with TLS:

```bash
curl -LO https://github.com/KyraLabs/easyrelay/raw/main/deploy/docker-compose.yml
RELAY_DOMAIN=relay.example.com docker compose up -d
```

This runs easyrelay behind Caddy, which obtains and renews the certificate on its own. See
[operations.md](docs/operations.md) for the systemd equivalent and for tuning.

Change something:

```bash
easyrelay init > easyrelay.zon   # a commented file with every default filled in
```

Every setting has a working default, so the file only needs the lines you actually want to
change. Configuration is validated at startup: an unknown key or an impossible value stops the
relay with a message naming the key, never a silently ignored line.

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

**To run it:** nothing. A prebuilt binary has no dependencies — no database server, no runtime,
no system packages. LMDB and `libsecp256k1` are compiled into it. The compose path additionally
needs a container runtime.

**To build it:** Zig `0.16.0`, pinned in `.zigversion` and installable with
[mise](https://mise.jdx.dev). Still no system packages: the dependencies are vendored and
compiled from source, and Zig ships its own C compiler. See
[development.md](docs/development.md).

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md). In short:

```bash
mise install     # pinned Zig 0.16.0
zig build test
```

- [Development guide](docs/development.md) — commands, layout, code conventions
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) — report vulnerabilities privately, never as an issue
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
