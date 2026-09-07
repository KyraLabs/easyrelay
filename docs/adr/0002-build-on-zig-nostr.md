# 0002. Build on `zig-nostr/nostr`

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

A relay needs the Nostr protocol primitives: the event model, canonical NIP-01 serialization,
SHA-256 event ids, BIP-340 Schnorr verification, filter representation and matching, and an
indexed event store. None of this is relay-specific; all of it is exacting, and getting the
canonical serializer subtly wrong produces a relay whose events no client will accept.

[`zig-nostr/nostr`](https://github.com/zig-nostr/nostr) provides all of it. Verified against
upstream:

- Version 0.12.0, self-described as "early", with the note that APIs may change before 1.0.
- Pins Zig `0.16.0` in `.zigversion`, matching [ADR-0001](0001-language-and-toolchain.md).
- Vendors and compiles `libsecp256k1` and LMDB from source, so no system packages are needed.
  Confirmed relevant locally: `libsecp256k1` is not installed on the development machine.
- Passes the full official BIP-340 test-vector suite.
- `src/` contains `event.zig` (14 KB), `filter.zig` (11 KB), `message.zig` (15 KB) and
  `store.zig` (116 KB) — the last being a zero-copy memory-mapped LMDB store with a bounded,
  newest-first query planner and indexes on author, kind, tags and `created_at`.
- Complete NIPs: 01, 06, 09, 19, 21, 42, 44, 46, 49, 65.

The countervailing facts are equally clear. It is pre-1.0 with a stated intent to change APIs.
It is designed local-first and client-oriented, and has two shipped consumers, both desktop
applications. Its store has never been exercised under a server workload: many concurrent
readers against a single writer, deletion, expiration, counting, search.

## Decision

Depend on `zig-nostr/nostr` for the protocol layer and, subject to validation, for the storage
backend. Do not reimplement event handling, canonical serialization, signature verification or
filter matching.

This decision is conditional on the Phase 0 validation spike
([roadmap](../roadmap.md#phase-0--foundation-and-validation-spike)), which must return a written
go/no-go on the store before Phase 2 begins.

## Consequences

The hardest and most failure-prone parts of the protocol arrive already tested against the
official vectors. easyrelay's own work starts at the server layer, which is where its value is.

Building `libsecp256k1` and LMDB from source removes the system-package burden for both
contributors and operators. This is a genuine deployment simplification, not just convenience.

In exchange, easyrelay inherits a pre-1.0 API surface. Upgrades may require migration work, and
a change to canonical serialization or signature behaviour would be severe. The vector suite in
`tests/vectors/` runs on every build specifically to catch that class of regression at upgrade
time rather than in production.

easyrelay is also exposed to the project's continuity. It is young and small. If it stalls, the
protocol layer would need to be vendored and maintained in-tree. That is unwelcome but bounded —
it is a known quantity of well-specified work, not an open-ended risk.

The store risk is different in kind, because it is the part least aligned with the dependency's
design intent. It is contained by [ADR-0008](0008-store-abstraction-boundary.md), which keeps
every `zig-nostr` type inside a single file.

## Alternatives considered

**Implement everything from scratch.** Total control and no upstream API risk. Rejected: it
front-loads months of work reimplementing a canonical serializer, a Schnorr integration and an
LMDB index scheme that already exist and are tested, and it does so at the point in the project
where momentum matters most. The failure mode is also worse — a bug in a from-scratch serializer
is invisible until clients reject the relay's events.

**Use `zig-nostr` for cryptography only, with a first-party store.** Isolates the risk to the
most stable component. Rejected as the starting point but retained as the fallback: it is
exactly what Phase 0 switches to on a no-go verdict. Adopting it pre-emptively would mean paying
for a bespoke index scheme without first checking whether the existing one suffices.

**Bind `nostrdb` (C) through `@cImport`.** A mature, battle-tested store from the Damus project,
directly consumable from Zig. Genuinely viable, and worth reconsidering if the Phase 0 verdict
is no-go, since it would be less work than a first-party schema. Not chosen now because mixing
a C store with a Zig protocol layer means two event representations and a conversion at the
boundary, on the hot path.

## Outcome of the Phase 0 spike (2026-08-23)

The spike this record made the decision conditional on has reported: **go**. Full evidence in
[the spike document](../research/2026-08-phase-0-validation.md).

What the spike found better than assumed: NIP-09 deletion is complete and correct, the
replacement tie-break and kind classification match [protocol.md](../protocol.md) exactly, and
the query planner is already the bounded newest-first design [storage.md](../storage.md)
specifies — a `limit: 500` query over 50,000 events examined exactly 500 index entries.

What it found worse: writes commit one transaction per event, which is **92 events/s** durably
on disk against **169,491 events/s** batched. The batch API that closes that gap skips the
protocol semantics, so the library currently offers a correct path too slow for production and
a fast path that is incorrect. No public API accepts an externally-owned transaction, so
easyrelay's own indexes cannot commit atomically with the event. `OpenOptions` exposes neither
`max_readers` nor the sync mode.

The decision stands, with three upstream contributions attached — a protocol-aware batch
ingest, caller-owned transactions, and the two missing options. They are additive and small,
and far cheaper than the alternative this record rejected. If upstream declines them, easyrelay
vendors the patch; [ADR-0008](0008-store-abstraction-boundary.md) is what keeps that contained.

## Amendment (2026-09-07): the storage clause is superseded

The three upstream conditions above were never filed. Upstream has no open pull requests and no
issue matching any of them, and `src/store.zig` is unchanged between v0.12.0 and v0.13.0. Nothing
was refused; nothing was asked. Recorded here because the sentence "with three upstream
contributions attached" describes a state that never existed, and a reader would otherwise take
it for one.

Phase 2 found further gaps between the dependency's store and what
[storage.md](../storage.md) specifies, the largest being that no monotonic local id exists.
[ADR-0010](0010-first-party-lmdb-store.md) is the result: easyrelay implements its own LMDB store
and **the storage clause of the decision above no longer holds**.

What stands is the rest of it, which is most of it. `zig-nostr/nostr` remains the protocol layer
— event handling, canonical serialization, signature verification, filter matching — and the
reasoning in Context and Consequences applies to it unchanged. The vector suite remains the
tripwire on exactly that surface.

## Revisit when

`zig-nostr/nostr` publishes a breaking release, or the project shows six months without
maintenance activity. The storage conditions are no longer a trigger: they were resolved by
[ADR-0010](0010-first-party-lmdb-store.md) rather than by upstream.
