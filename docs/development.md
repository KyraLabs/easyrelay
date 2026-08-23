# Development

## Toolchain

**Zig `0.16.0`, exactly.** Pinned in `.zigversion`. Zig is pre-1.0 and every release breaks
something; the version is not a floor, it is a pin. See
[ADR-0001](adr/0001-language-and-toolchain.md).

With [mise](https://mise.jdx.dev):

```bash
mise install
zig version   # must print 0.16.0
```

Nothing else is required. `libsecp256k1` and LMDB are vendored and compiled from source by the
dependency graph, and Zig ships its own C compiler, so there are no system packages to install
and no `pkg-config` to satisfy.

## Commands

```bash
zig build              # build the relay
zig build run          # build and run with ./easyrelay.zon
zig build test         # unit, vector and conformance tests
zig build test --summary all
zig fmt --check .      # formatting gate, same as CI
zig build bench        # benchmark harness
zig build fuzz         # fuzz targets
```

Run a single test file while iterating:

```bash
zig build test -Dtest-filter="replaceable"
```

## Dependencies

Declared in `build.zig.zon`, every one pinned to an exact release with its hash. No branch
references, no `main`.

| Dependency | Purpose | Record |
| --- | --- | --- |
| [`zig-nostr/nostr`](https://github.com/zig-nostr/nostr) | Event model, canonical serialization, Schnorr, filters, LMDB store | [ADR-0002](adr/0002-build-on-zig-nostr.md) |
| [`websocket.zig`](https://github.com/karlseguin/websocket.zig) | WebSocket server | [ADR-0004](adr/0004-websocket-transport.md) |
| [`zig-lmdb`](https://github.com/nDimensional/zig-lmdb) | Direct LMDB access, if the first-party schema is needed | [ADR-0003](adr/0003-storage-engine-lmdb.md) |

Adding a dependency requires an ADR. The cost of a dependency in a pre-1.0 language ecosystem is
paid on every compiler upgrade, and that cost belongs in a written decision.

Upgrading one:

```bash
zig fetch --save=nostr https://github.com/zig-nostr/nostr/archive/refs/tags/vX.Y.Z.tar.gz
zig build test
```

The vector suite is the tripwire here: a dependency upgrade that changes canonical serialization
or signature behaviour fails those tests immediately rather than silently producing events no
client will accept.

## Repository layout

See [architecture.md](architecture.md#repository-layout). Two rules the layout encodes:

- **Layers depend downward only.** `server/` may call `relay/`, `relay/` may call `storage/`,
  never the reverse. A storage backend does not know what a WebSocket is.
- **No dependency type crosses the `Store` boundary.** `zig-nostr` types stay inside
  `storage/lmdb.zig`. Everything above sees easyrelay's own types. See
  [ADR-0008](adr/0008-store-abstraction-boundary.md).

## Conventions

**Formatting** is whatever `zig fmt` produces. It is not a matter of preference and CI enforces
it.

**Naming** follows the Zig standard: `TitleCase` for types, `camelCase` for functions,
`snake_case` for variables and fields, `SCREAMING_SNAKE_CASE` for constants.

**Allocators are explicit and passed in.** No hidden globals. Long-lived state uses the
general-purpose allocator; per-request work uses an arena reset per message, which is both
faster and impossible to leak.

**Errors are values.** Every error is either handled or propagated with an error union. No
`catch unreachable` on a path an untrusted client can reach, and no swallowed errors. An error
returned to a client carries the appropriate machine-readable prefix from
[protocol.md](protocol.md#machine-readable-result-prefixes).

**Comments explain why, not what.** Assume the reader knows Zig. A comment earns its place by
recording a decision, a constraint, or a non-obvious interaction — the tie-break rule for
replaceable events deserves one; a loop over tags does not.

**Tests live next to the code** for unit tests, and in `tests/` for vectors and conformance.

## Working on a phase

1. Read the phase in the [roadmap](roadmap.md), including its exit criteria.
2. Write the conformance tests first, from [protocol.md](protocol.md) and the NIP text — not
   from the implementation.
3. Implement.
4. Update [nips.md](nips.md) in the commit that turns the tests green.
5. Verify every exit criterion for the phase before calling it done.

If implementation reveals that a documented decision was wrong, amend the ADR in the same pull
request. A stale ADR is worse than no ADR, because it will be trusted.
