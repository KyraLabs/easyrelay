# Development

## Toolchain

**Zig `0.16.0`, exactly.** Pinned in `.zigversion`. Zig is pre-1.0 and every release breaks
something; the version is not a floor, it is a pin. See
[ADR-0001](adr/0001-language-and-toolchain.md).

With [mise](https://mise.jdx.dev), which reads `mise.toml`:

```bash
mise install
zig version   # must print 0.16.0
```

The pin appears in three files that have to agree — `.zigversion`, `mise.toml`, and
`minimum_zig_version` in `build.zig.zon`. `./scripts/check-toolchain.sh` enforces that and CI
runs it, so drift fails a pull request instead of surfacing later as an unrelated build error.

Nothing else is required. `libsecp256k1` and LMDB are vendored and compiled from source by the
dependency graph, and Zig ships its own C compiler, so there are no system packages to install
and no `pkg-config` to satisfy.

### Hosts with an SFrame `crt1.o`

On a distribution recent enough to ship SFrame unwind data in its C runtime — Arch with
gcc 16 / binutils 2.47 is one — a native build that links libc fails in the linker:

```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c
    note: in .../crt1.o:.sframe
```

Zig 0.16's ELF linker cannot relocate the host's `.sframe` section. Pass an explicit target so
Zig uses its own bundled start files instead:

```bash
zig build -Dtarget=x86_64-linux-musl      # static, and what releases ship
zig build -Dtarget=x86_64-linux-gnu.2.39
```

The build links libc now that the `zig-nostr` dependency has landed, so on such a host this is
every native build, tests included. CI runs Ubuntu and is unaffected. Diagnosed in the
[Phase 0 validation spike](research/2026-08-phase-0-validation.md#an-environment-finding-that-affects-everyone-on-this-machine).

## Commands

Available now:

```bash
zig build                    # build the relay into zig-out/bin/
zig build run                # build and run it
zig build test               # run all tests
zig build test --summary all # ... with a per-step summary
zig build check              # type-check without producing artifacts (fast editor diagnostics)
zig fmt --check --exclude zig-pkg .   # formatting gate, identical to CI
./scripts/check-toolchain.sh # verify the Zig pin agrees across all three files
./scripts/interop-nak.sh     # publish and read back with nak, against the built binary
```

The interop script needs [`nak`](https://github.com/fiatjaf/nak) on `PATH` and a relay binary in
`zig-out/bin/`. It starts the relay on its default port, so nothing else may be listening on
7777 while it runs — the transport sets `SO_REUSEPORT`, so the script checks rather than
discovering it as a confusing failure.

Run a subset of tests while iterating:

```bash
zig build test -Dtest-filter="replaceable"
```

Fuzz a target once the fuzz tests exist (Phase 1 onward). Zig's fuzzer is driven through the
test runner rather than a separate step:

```bash
zig build test --fuzz
```

Added by later phases: `zig build bench` (the harness in `bench/`, Phase 6).

## Dependencies

Declared in `build.zig.zon`, every one pinned to an exact revision with its content hash — a
release tag where upstream publishes one. No branch references, no `main`.

| Dependency | Purpose | Record |
| --- | --- | --- |
| [`zig-nostr/nostr`](https://github.com/zig-nostr/nostr) | Event model, canonical serialization, Schnorr, filters, LMDB store | [ADR-0002](adr/0002-build-on-zig-nostr.md) |
| [`websocket.zig`](https://github.com/karlseguin/websocket.zig) | WebSocket server | [ADR-0004](adr/0004-websocket-transport.md) |
| [`zig-lmdb`](https://github.com/nDimensional/zig-lmdb) | Direct LMDB access, if the first-party schema is needed | [ADR-0003](adr/0003-storage-engine-lmdb.md) |

`websocket.zig` is pinned to a **commit** rather than a tag: its Zig 0.16 support lives on
`master`, and its only release tag predates it. The pin is immutable and hashed, which is what
the rule is there for, but an upgrade is a deliberate choice of a newer commit rather than a
version bump, and there are no release notes to read before taking it.
[ADR-0004](adr/0004-websocket-transport.md) already tracks when to revisit that.

Adding a dependency requires an ADR. The cost of a dependency in a pre-1.0 language ecosystem is
paid on every compiler upgrade, and that cost belongs in a written decision.

Upgrading one:

```bash
zig fetch --save=nostr https://github.com/zig-nostr/nostr/archive/refs/tags/vX.Y.Z.tar.gz
zig fetch --save=websocket https://github.com/karlseguin/websocket.zig/archive/<commit>.tar.gz
zig build test
```

The vector suite is the tripwire here: a dependency upgrade that changes canonical serialization
or signature behaviour fails those tests immediately rather than silently producing events no
client will accept.

## Repository layout

See [architecture.md](architecture.md#repository-layout). Two rules the layout encodes:

- **Layers depend downward only.** `server/` may call `relay/`, `relay/` may call `storage/`,
  never the reverse. A storage backend does not know what a WebSocket is.
- **No store type crosses the `Store` boundary.** `zig-nostr`'s store types stay inside
  `storage/lmdb.zig`; everything above sees easyrelay's own `Store` types. Its protocol
  primitives — events, filters, messages, keys — are shared vocabulary and may appear anywhere.
  See [ADR-0008](adr/0008-store-abstraction-boundary.md).

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
