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

1. **No type from `zig-nostr`'s store appears outside `src/storage/lmdb.zig`.** Not in a
   function signature, not in a struct field, not in an error set. Everything above the
   boundary sees easyrelay's own `Store` types. The dependency's protocol primitives —
   `event.zig`, `filter.zig`, `message.zig`, `keys.zig` — are shared vocabulary and are not
   covered by this rule; see the amendment below.
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

## Outcome of the Phase 0 spike (2026-08-23)

The spike returned **go** on the store, so the replacement schema this boundary protects against
is not needed. The boundary is nonetheless doing more work than anticipated, not less.

Two of the spike's findings land squarely on it. The dependency commits one transaction per
event, so the interface needs a batch entry point that easyrelay's writer thread drives — a
shape the dependency does not currently offer, and which the adapter has to provide. And the
dependency queries a single filter while a `REQ` carries several, so merging, deduplicating and
applying `limit` across the merge is adapter work too.

Both are exactly what rule 2 of this record anticipated: the interface is defined by what the
relay needs, and `lmdb.zig` absorbs the difference. If the upstream conditions in
[ADR-0002](0002-build-on-zig-nostr.md) are declined and easyrelay vendors a patch, this boundary
is what keeps that a one-file change.

## Amendment (2026-08-23): rule 1 covers the store's types, not the protocol primitives

As first written, rule 1 forbade any `zig-nostr` type outside `src/storage/lmdb.zig` and had the
protocol and core layers seeing easyrelay's own types exclusively. That contradicted two
documents written the same day: [ADR-0002](0002-build-on-zig-nostr.md), whose decision is
explicitly not to reimplement event handling, canonical serialization or filter matching, and
[architecture.md](../architecture.md#protocol), which has the protocol layer consuming
`event.zig`, `filter.zig` and `message.zig` directly. It also reached past this record's own
Context, which is about the store and only the store.

The rule now says what it was written to say. Above `src/storage/lmdb.zig`:

- **Forbidden:** anything from the dependency's `store.zig` — its store handle, its
  transactions, its cursors, its query results, its error set.
- **Allowed:** the protocol primitives in `event.zig`, `filter.zig`, `message.zig` and
  `keys.zig`. They are the dependency's spec-defined surface and they are what
  [ADR-0002](0002-build-on-zig-nostr.md) was taken to obtain. Mirroring them behind easyrelay
  types would be reimplementation by another name, which is the alternative that record
  rejected.

easyrelay's `Store` interface therefore speaks in protocol types and never in the dependency's
store types. The property this record exists to protect is unchanged: replacing the backend,
whether with a first-party LMDB schema or a vendored patch, changes `lmdb.zig` and nothing above
it, because no signature above the boundary names a type that would change with it.

The cost is real and belongs here. A breaking release of the dependency's event or filter model
now reaches the protocol and core layers rather than one file. Three things bound it: those
types are small and shaped by NIP-01 rather than by the dependency's taste; the vector suite in
`tests/vectors/` fails immediately on a semantic change; and ADR-0002 already contemplates
vendoring the protocol layer if upstream stalls.

Amended in place rather than superseded by a new record because the decision — all data access
through a first-party interface — is untouched. What changed is a supporting rule that
overreached past the risk it was written to contain, which is the correction of a factual error
the [records README](README.md) allows.

## Revisit when

A measured cost on the read path shows the boundary forcing copies that cannot be designed away.
