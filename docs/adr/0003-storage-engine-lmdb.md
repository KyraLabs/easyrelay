# 0003. LMDB with custom indexes, not SQL

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

The relay must answer NIP-01 filter queries — a small, closed query language — over a store that
grows without bound and is read far more than it is written. The realistic options are an
embedded SQL engine (SQLite) or a key-value store with hand-built indexes (LMDB).

The relevant precedent is unambiguous. strfry, the performance reference in this space, uses
LMDB with custom indexes. nostrdb copies that index design almost exactly. rnostr uses LMDB.
`zig-nostr/nostr`'s store uses LMDB. nostr-rs-relay uses SQLite and is the widely deployed
counterexample, aimed explicitly at small machines rather than at throughput.

## Decision

LMDB, with the indexes specified in [storage.md](../storage.md). No SQL engine.

Access is through `zig-nostr/nostr`'s store, or through
[`zig-lmdb`](https://github.com/nDimensional/zig-lmdb) (release `v0.4.0+0.9.35` for Zig 0.16) if
Phase 0 returns a no-go and a first-party schema is needed.

## Consequences

Reads are memory-mapped and zero-copy: an event is served from the page cache without being
parsed or copied. Query cost becomes a function of the requested page size rather than of the
store's total size, which is the property that matters as a relay ages.

No query planner means no planner surprises. Index selection is a fixed, readable function of
the filter's shape, and its behaviour does not change because statistics drifted.

Writes serialise. LMDB's write lock is process-wide, which forces the single-writer thread in
[ADR-0005](0005-concurrency-model.md). That is a constraint accepted deliberately, not a
limitation to be engineered around.

Every index is hand-maintained. Adding one — for NIP-50 search, for instance — means writing the
key encoding, the insert path, the delete path and the migration. SQLite would have made that a
`CREATE INDEX`. This is the real cost of the decision and it is paid in Phase 4.

Two LMDB properties leak into the design and must be documented for operators: the map size is a
hard ceiling fixed at startup, and long-lived read transactions pin pages and prevent reuse. Both
are covered in [storage.md](../storage.md) and [operations.md](../operations.md).

## Alternatives considered

**SQLite.** Mature Zig bindings exist (`zqlite.zig` supports 0.16), indexes are declarative,
NIP-50 could ride on FTS5, and ad-hoc inspection with the `sqlite3` CLI is genuinely useful in
production. Rejected because filter queries would go through a general-purpose planner and row
decoding on every read, when the access pattern is known in advance and needs neither. It is the
right answer for a relay optimising for small machines and operator convenience; it is not the
right answer here.

**PostgreSQL.** Rejected outright: it contradicts single-binary deployment, which is a stated
goal in [overview.md](../overview.md). `mattn/zig-nostr-relay` demonstrates the approach.

**A first-party storage engine.** Rejected without serious consideration. Writing a durable,
crash-safe storage engine is a larger project than the relay.

## Revisit when

NIP-50 search proves impractical to index by hand, or a workload appears whose queries the fixed
index set genuinely cannot serve.
