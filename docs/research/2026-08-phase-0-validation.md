# Phase 0 validation spike — go/no-go

- **Date:** 2026-08-23
- **Subjects:** `zig-nostr/nostr` v0.12.0 (store) and `websocket.zig` `master` (transport)
- **Verdict:** **GO on both**, with three conditions on the store recorded below.

This is the written verdict [Phase 0](../roadmap.md#phase-0--foundation-and-validation-spike)
requires before anything is built on these dependencies. The spike code was throwaway and is
not in the repository; every number here was produced by running it, and the conditions it
ran under are stated so they can be disputed.

## Method

Two standalone programs outside the repository, built with the project's pinned Zig `0.16.0`.

Measurements were taken in **ReleaseSafe**, with the LMDB store on **btrfs** (a real disk), at
LMDB's **default durability** — metadata synced on commit. An earlier pass ran in Debug with the
store on `/tmp`, which is `tmpfs`; those numbers are excluded, because `fsync` on a RAM
filesystem is close to free and every write figure taken there is meaningless. This is the rule
[testing.md](../testing.md#benchmarks) sets for published numbers, and it applies to the spike
that informs the design as much as to a release announcement.

Hardware: the development machine, Linux 7.1.8, x86_64. Absolute figures are not portable; the
**ratios** are the finding.

## Summary

| # | Question | Verdict |
| --- | --- | --- |
| Q1 | Concurrent readers alongside a single writer? | **Yes**, capped at 126 reader threads |
| Q2 | Deletion and expiration? | **Deletion yes** (complete), **expiration no** |
| Q3 | Does the query planner cover every NIP-01 filter shape? | **Yes**, 16/16 |
| Q4 | Can easyrelay own the write transaction boundary? | **No** |
| Q5 | Does `websocket.zig` hold N connections on 0.16 without dropping frames? | **Yes**, 3000 tested |
| Q6 | Does it leak? | **No** |

29 of 30 assertions passed. The one failure is Q1's reader ceiling, which is a documented LMDB
limit rather than a defect, and is analysed below.

## Q1 — Concurrent readers with a single writer: yes, with a hard ceiling

Eight reader threads querying continuously alongside one writer thread ingesting 2000 events:
**314,531 reads, 2000 writes, zero errors**, and the final event count matched the writes
exactly. `Store`'s fields are the LMDB environment handle and the sub-database handles, none of
which is mutated after `open`, so sharing one `*Store` across threads is structurally sound.
Every method opens and commits its own transaction; reads use `MDB_RDONLY`.

At **200 reader threads the picture changes**: 575,061 of 1,990,917 read attempts failed, about
29%. This is LMDB's `max_readers`, which defaults to 126. The store never calls
`mdb_env_set_maxreaders`, and `OpenOptions` exposes only `map_size` and `max_dbs` — **there is
no way to raise the limit from outside the library.**

For easyrelay this is livable: the I/O pool is sized to core count, not to connections, so it
stays far below 126. It becomes a problem in two places, and both need to be written down now:
a deployment that sizes the pool aggressively on a large machine, and the Phase 6 evented
migration, where the environment is also opened without `MDB_NOTLS` and reader slots are bound
to threads — coroutines migrating between threads would not be safe against this API.

One related find: `keys.Signer` documents itself as **not thread-safe** for concurrent use of a
single instance. Signature verification therefore needs one `Signer` per I/O thread, not one
shared instance. That is a Phase 1 detail worth catching before it becomes a race.

## Q2 — Deletion is complete; expiration does not exist

**NIP-09 is implemented, and correctly.** Verified by experiment:

- Another author's deletion request is ignored — the target survives.
- The author's own deletion removes the target.
- The kind-5 request itself is stored, so the deletion propagates to peers that sync.
- The deleted id is tombstoned, and re-submitting the same event afterwards returns `deleted`
  rather than silently reinstating it.

The store also handles `a`-tag (addressable) deletions and refuses to apply one to an event
newer than the deletion. This is more than [nips.md](../nips.md) assumed easyrelay would have
to build.

Three related semantics were verified while there, all correct: ephemeral kinds are not
persisted; a newer replaceable event supersedes the older one and removes it; an older one is
rejected as `stale`. The replacement tie-break is `created_at`, then the lexicographically lower
id — exactly what [protocol.md](../protocol.md#kind-semantics) specifies. `classify()`'s kind
ranges match that document too.

**NIP-40 expiration is absent.** An event carrying `["expiration", "1"]` — expired in 1970 — is
stored and returned by queries. There is no expiration index and no reaper. This is
easyrelay's to build, exactly as [storage.md](../storage.md#expiration-nip-40) plans, and it
runs into Q4.

## Q3 — Filter coverage: complete

Sixteen shapes drawn from [protocol.md](../protocol.md#filters), all passing:

`ids` · `authors` · `kinds` · `authors`+`kinds` · single tag · **two tags AND-ed** ·
`since` inclusive · `until` inclusive · `since`+`until` window · `limit` · empty filter ·
unmatchable filter · non-matching tag value · newest-first ordering · `limit` selecting the
*newest* events · bounded `examined`.

The planner is a bounded newest-first k-way merge over reverse cursors, with `since`/`until` as
key bounds and the full filter applied as a post-filter. On a **50,000-event store a
`limit: 500` query took 1.3 ms and examined exactly 500 index entries** — no waste at all. That
is the "flat as it grows" property [storage.md](../storage.md#query-planning) is designed
around, and it is already there. The store also reports `examined` and `list_checks` per query,
which is better observability than easyrelay had specified.

**One gap:** `query()` takes a *single* `Filter`, while a NIP-01 `REQ` carries several, OR-ed.
easyrelay must run one query per filter and merge, deduplicate by id, and apply the
subscription's `limit` across the merged result rather than per filter. Applying `limit`
per-filter and concatenating would return the wrong events — this is a correctness trap for
Phase 1 and belongs in the conformance suite.

## Q4 — The write transaction boundary: no, and this is the important one

Every public write method — `put`, `putEvent`, `putEventBatch`, `ingest` — opens its own
transaction and commits before returning. No public API accepts an externally-owned
transaction. **easyrelay cannot commit its own index in the same transaction as the event.**

The consequence is not theoretical. NIP-40 expiration (Phase 3) and NIP-50 search (Phase 4) both
need an index easyrelay maintains itself. With this API, inserting an event and updating that
index are two commits, and a crash between them leaves the two inconsistent. The recovery is a
consistency check on startup, which is real work and grows with the store.

The second consequence is throughput, and it is severe:

| Path | Durable, on disk | Notes |
| --- | --- | --- |
| `ingest()` — one transaction per event | **92 events/s** | Protocol-aware: replaceable, deletion, ephemeral |
| `putEventBatch()` — one transaction | **169,491 events/s** | Low-level insert; **no** protocol semantics |

A factor of **1,842**. The entire difference is `fsync` per commit, and it is the difference
between a relay that can serve traffic and one that cannot: 92 events/s is not a production
relay by any reading of [overview.md](../overview.md#2-it-is-fast).

The fast path is unusable as-is, because `putEventBatch` is documented as the low-level insert
that skips exactly the semantics a relay must apply. So the library currently offers a correct
path that is too slow and a fast path that is incorrect.

For contrast, signature verification — the cost everyone assumes dominates — runs at
**21,551 events/s single-threaded**, about 46 µs per event. Crypto is not the bottleneck and
does not need optimising. Storage commit strategy is the whole story.

Also measured, resolving an open worry: reopening a 50,000-event store takes **1 ms**. The
index validation that runs on every `open` is a cheap count check, not a rebuild.

## Q5 and Q6 — Transport: holds up, does not leak

`websocket.zig` `master` compiled against Zig 0.16 on the first attempt, despite upstream's
"not well tested … consider this experimental" warning.

An echo server was driven by a client opening N connections, each sending numbered messages and
verifying every echo byte-for-byte and in order — the check that catches a dropped or
interleaved frame, which is the actual risk.

| Load | Result |
| --- | --- |
| 200 connections × 50 messages | 10,000/10,000 echoed, 0 mismatched, 0 failed |
| 1000 connections × 5 messages, held open | 5,000/5,000, 1007 file descriptors, RSS 6.5 MB |
| 3000 concurrent connections | 9,000/9,000, 0 mismatched, 0 failed |
| ~13,000 connection lifecycles total | server survived, no errors logged |

**On the leak question, the first answer was wrong and worth recording.** An initial run showed
RSS climbing about 2 MB per 1000-connection cycle, perfectly linear, never returning — which
looks exactly like a per-connection leak. It was not: the spike had handed the server
`init.arena.allocator()`, and an arena never frees. With a real freeing allocator, RSS rises to
a high-water mark and stops: 6.8 MB after the first cycle, drifting to 10.3 MB over ten, then
pinned at **12,480 kB after a 3000-connection burst and byte-identical across the two cycles
that followed**. Memory tracks peak concurrency, not connections served. Roughly 3 KB per
connection at peak.

A gotcha for Phase 1: **`Client.write` masks the payload in place**, mutating the caller's
buffer, because client frames are masked. Anything that needs the sent bytes afterwards must
copy them first.

## An environment finding that affects everyone on this machine

Building anything that links libc fails on this host:

```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c
    note: in .../crt1.o:.sframe
```

The host is gcc 16.2.1 with binutils 2.47, and `/usr/lib/crt1.o` carries a `.sframe` section
that Zig 0.16's ELF linker cannot relocate. It is not a zig-nostr problem — 19 of 22 build steps
succeeded, including compiling libsecp256k1 and LMDB from source; only the final link failed.

Passing an explicit target makes Zig use its own bundled start files, and both work:

```bash
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=x86_64-linux-gnu.2.39
```

This will hit easyrelay the moment it takes the zig-nostr dependency, and it needs to be in
[development.md](../development.md) before someone loses an afternoon to it. CI runs Ubuntu and
is unaffected.

## Verdict and conditions

**Store: GO.** The semantics are right where it matters most and cheapest to get wrong — the
canonical model, the kind classification, the replacement tie-break, NIP-09, and a query planner
that is already what [storage.md](../storage.md) specifies. Reproducing that would take months
and would be worse. [ADR-0002](../adr/0002-build-on-zig-nostr.md) stands and does not need
amending.

Three conditions, all additive and small, and all better fixed upstream than worked around:

1. **A batched, protocol-aware ingest.** `ingestBatch` applying the same semantics as `ingest`
   inside one transaction. Without it the relay chooses between 92 events/s and incorrect
   semantics. This is the blocking one for Phase 2.
2. **An externally-owned transaction.** Public write methods accepting an optional caller
   transaction, so easyrelay's expiration and search indexes commit atomically with the event.
3. **`OpenOptions` for `max_readers` and sync mode.** The reader ceiling cannot be raised and
   durability cannot be traded off, both because the option is not exposed.

Recommended order: propose all three upstream; if they are declined or slow, vendor a patch.
That is far cheaper than the first-party LMDB schema
[ADR-0008](../adr/0008-store-abstraction-boundary.md) holds in reserve — and the boundary that
ADR defines is what makes vendoring a contained change rather than a fork.

**Transport: GO.** [ADR-0004](../adr/0004-websocket-transport.md) stands. 3000 concurrent
connections with zero dropped or corrupted frames and bounded memory is well beyond what
Phase 1 needs, and the experimental label did not show up as instability in this test. The
first-party RFC 6455 fallback stays unused.

One caveat, stated plainly: this exercised the happy path at scale. It did not test malformed
frames, hostile fragmentation, slow-loris handshakes, or a client that stops reading. Those
belong to Phase 3's hardening, and they are where an experimental transport is most likely to
disappoint.

## What this changes in the documentation

| Document | Change |
| --- | --- |
| [development.md](../development.md) | The `-Dtarget` requirement on hosts with SFrame crt1.o |
| [storage.md](../storage.md) | Store is a single file (`MDB_NOSUBDIR`), not a directory — the backup procedure assumed a directory |
| [architecture.md](../architecture.md) | Expiration is easyrelay-side; the `Store` interface needs a batch entry point |
| [roadmap.md](../roadmap.md) | Phase 2 gains the batching work and the multi-filter `REQ` merge; Phase 3's NIP-40 is confirmed first-party |
| [nips.md](../nips.md) | NIP-09 arrives with the dependency rather than being built in Phase 3 |
