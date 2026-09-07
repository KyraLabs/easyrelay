# 0010. A first-party LMDB store, not the dependency's

- **Status:** Accepted
- **Date:** 2026-09-07

## Context

[ADR-0002](0002-build-on-zig-nostr.md) made `zig-nostr/nostr` the storage backend, subject to the
Phase 0 spike, which returned go. [ADR-0003](0003-storage-engine-lmdb.md) reserved a first-party
schema on [`zig-lmdb`](https://github.com/nDimensional/zig-lmdb) for a no-go verdict, and
[ADR-0008](0008-store-abstraction-boundary.md) built the boundary that would contain such a
switch.

Phase 2 opened by reading v0.12.0's `store.zig` against what [storage.md](../storage.md)
specifies. Four facts, each verified in the source rather than inferred:

- **There is no monotonic local id.** Events are keyed by their 32-byte event id and ordered
  through a `[created_at][event_id]` index. storage.md's data model — every index mapping into a
  dense 64-bit insertion counter — is not what the backend implements, and the Phase 0 spike
  never checked. The Phase 2 watermark that closes Phase 1's duplicate-delivery window was
  specified against that counter.
- **Batching and kind semantics cannot be combined.** `putEventBatch` commits a whole batch in
  one transaction and documents itself as applying neither replaceable nor deletion semantics.
  `ingest` applies them, through helpers that each open their own transaction and accept no
  external one. Phase 0 measured what that costs: 92 events/s durable per event against 169,491
  batched. ADR-0002 recorded this accurately.
- **Reads are copied, not streamed.** `query` returns a `QueryResult` owning an arena that holds
  the matched events. The copy is bounded by `limit` rather than by the store's size, so the
  bounded-scan property survives, but ADR-0008's zero-copy sink is not reachable over it.
- **The index set is a client's.** One replacement index covering replaceable and addressable
  coordinates together, no expiration index, and a direct-message conversation index that a relay
  has no use for.

The three upstream contributions ADR-0002 attached to its verdict were never filed. Upstream has
no open pull requests and no issue matching any of them: nothing was refused, nothing was asked.
`src/store.zig` is unchanged between v0.12.0 and v0.13.0, the newest release.

None of this is a fault in the dependency. Its store is built for local-first client
applications, which ADR-0002 stated plainly, and it serves them. The mismatch is that a relay
needs a different shape.

## Decision

easyrelay implements its own LMDB store in `src/storage/lmdb.zig`, on
[`zig-lmdb`](https://github.com/nDimensional/zig-lmdb), behind the existing `Store` interface.
[storage.md](../storage.md) stops being a model the backend approximates and becomes the one this
code implements, local ids included.

`zig-nostr/nostr` remains the protocol layer — `event.zig`, `filter.zig`, `message.zig` and
`keys.zig` — which is what ADR-0002 was taken to obtain and what `tests/vectors/` guards. Only the
store changes hands.

This supersedes the storage clause of [ADR-0002](0002-build-on-zig-nostr.md) and the access
clause of [ADR-0003](0003-storage-engine-lmdb.md). It leaves
[ADR-0008](0008-store-abstraction-boundary.md) standing: that boundary was built for this move,
and the memory backend it keeps as a differential oracle becomes considerably more valuable.

## Consequences

The data model becomes true by construction. The watermark, the batched writer and the scan
budget are ours to build rather than ours to request, so no part of Phase 2 waits on an answer
from a single upstream maintainer that may not arrive.

We own the indexes. ADR-0003 named this the real cost of choosing LMDB over SQL — each index is a
key encoding, an insert path, a delete path and a migration, written by hand — and this record is
where that cost is actually paid. It is the largest single piece of work in Phase 2 and the most
likely to be wrong in ways that tests, not review, have to catch.

Correctness that used to arrive free now has to be earned. Phase 0 verified the dependency's
NIP-09 deletion, its replacement tie-break and its kind classification against protocol.md.
Reimplementing them reimplements every chance to get them wrong. Two existing commitments stop
being optional as a result: conformance tests for kind semantics written from the NIP text before
the code, and the property test in [testing.md](../testing.md) that runs identical randomised
filters against the memory backend and this one and requires identical results.

A new direct dependency, `zig-lmdb`, replaces an indirect one. The C library underneath is the
same liblmdb the dependency already compiles from source, so nothing changes for operators or for
the single-binary deployment goal in [overview.md](../overview.md).

We forgo the dependency's future storage work. If upstream later grows a relay-shaped store, an
upgrade will not bring it to us.

## Alternatives considered

**Vendor the dependency's `store.zig` in-tree and patch it.** Copy 2,664 lines into
`src/storage/`, repoint its four sibling imports at the `nostr` module, add liblmdb directly, then
patch the four gaps. It starts from code Phase 0 validated, which is a genuine advantage.
Rejected because what needs changing is the data model and the write path — the core of the file
rather than its edges — so the copy would be largely rewritten while still carrying a client
store's assumptions and its conversation index, and every upstream fix would afterwards arrive as
a merge against a diverged file we did not write.

**Propose the changes upstream and wait.** Cheapest if accepted, and closed issue #33 shows the
maintainer does take store corrections. Rejected as Phase 2's path: the changes are structural
rather than additive, the project has one maintainer, and ADR-0002's own "Revisit when" names
conditions going unanswered long enough to block Phase 2 as the trigger to reconsider. The door
stays open — this work is useful upstream and can be offered once it is proven here.

**Accept the gaps and build Phase 2 around them.** That means no watermark, and choosing between
92 events/s durable and a batch path that silently skips replacement semantics. Rejected against
[overview.md](../overview.md)'s first two goals in their stated order: skipping replacement
semantics is incorrect, and 92 events/s is not a relay.

## Revisit when

`zig-nostr/nostr` grows a store built for server workloads — protocol-aware batched ingest,
caller-owned transactions, a monotonic insertion order and streaming reads — at which point the
comparison is worth making again on measurements rather than on this record's reasoning.
