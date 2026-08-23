# 0008. A first-party `Store` interface as an isolation boundary

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

[ADR-0002](0002-build-on-zig-nostr.md) makes `zig-nostr/nostr` a load-bearing dependency,
including for storage. That is the project's largest single risk, and it is concentrated in the
component least aligned with the dependency's design intent: its store is built for local-first
client applications, and easyrelay would be the first consumer to run it under a server
workload — many concurrent readers against a single writer, deletion, expiration, counting,
search.

The risk cannot be eliminated. It can be confined, and the difference between confining it and
not is the difference between a contained setback and a rewrite.

## Decision

All data access goes through a `Store` interface defined by easyrelay in `src/storage/store.zig`.

Two rules make it real:

1. **No `zig-nostr` type appears outside `src/storage/lmdb.zig`.** Not in a function signature,
   not in a struct field, not in an error set. The protocol and core layers see easyrelay's own
   types exclusively.
2. **The interface is defined by what the relay needs**, derived from
   [protocol.md](../protocol.md) and [storage.md](../storage.md), not by what the dependency
   happens to expose. Where the two differ, the adapter in `lmdb.zig` absorbs the difference.

The `memory` backend from Phase 1 is retained permanently rather than discarded. It keeps the
interface honest — a second implementation makes an abstraction leak visible immediately — and
it is what the property tests compare the indexed store against.

## Consequences

If Phase 0's validation spike returns no-go on the store, the replacement is a first-party LMDB
schema behind the same interface, built on
[`zig-lmdb`](https://github.com/nDimensional/zig-lmdb). Phase 2 changes; no other phase moves,
and no protocol or core code is touched. That property is the entire reason this record exists.

The same boundary makes the property test in [testing.md](../testing.md) possible: run identical
randomised filters against the memory backend's brute-force matching and the LMDB backend's
index-driven planner, and require identical results. This validates the index design itself,
not merely the code that reads it, and it is the highest-value test in the suite. It is only
available because two implementations share one interface.

The cost is an adapter layer and, in places, a conversion where the dependency's representation
does not match easyrelay's. On the read path this must not mean copying event bytes: the
interface streams results through a sink so that zero-copy reads stay zero-copy. Getting that
right is Phase 2 work and is the main design constraint on the interface's shape.

There is also a discipline cost. Rule 1 is easy to violate accidentally by returning a
dependency type from a convenience helper. Code review checks it explicitly.

## Alternatives considered

**Use `zig-nostr`'s store types directly throughout.** Less code, no adapter, no conversions.
Rejected: it makes the dependency's API surface into easyrelay's internal API, so a breaking
upstream release or a no-go verdict becomes a change across every layer instead of one file.
The saving is small and the exposure is unbounded.

**Define the interface by mirroring what `zig-nostr` exposes.** Would minimise adapter code
today. Rejected: an interface shaped by one implementation is not an abstraction, it is that
implementation with extra indirection, and it would fail at precisely the moment it is needed.

**Skip the memory backend after Phase 1.** Less code to maintain. Rejected: it is the
differential oracle for the property tests, and a single-implementation interface drifts into
leaking without anything to catch it.

## Revisit when

The Phase 0 validation spike reports, or a measured cost on the read path shows the boundary
forcing copies that cannot be designed away.
