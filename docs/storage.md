# Storage

## Engine

LMDB, embedded. No external database process, no SQL engine, no query planner beyond what the
NIP-01 filter language needs. The reasoning is in [ADR-0003](adr/0003-storage-engine-lmdb.md);
the concurrency consequences are in [architecture.md](architecture.md#concurrency-model).

The backend is `zig-nostr/nostr`'s zero-copy store, reached through easyrelay's own `Store`
interface ([ADR-0008](adr/0008-store-abstraction-boundary.md)). This document describes the
data model that backend must satisfy. It is written independently of that dependency so that it
also serves as the specification for a replacement, should Phase 0's validation spike return a
no-go.

## Data model

Events are stored once, serialized, and addressed everywhere else by a **local id**: a
monotonically increasing 64-bit integer assigned at insert time. Every index maps some key to a
local id rather than duplicating event data.

```
events:  local_id (u64 BE)  ->  serialized event bytes
```

Local ids are dense and increase with insertion order, which makes them a natural tie-break and
keeps index entries small. They are internal and never leave the process.

### Indexes

Every index key ends with `created_at` descending and then `local_id`, so that a cursor
positioned at `until` and walked backwards yields exactly the newest-first order that
[protocol.md](protocol.md#filters) requires, and can stop the moment `limit` is reached.

| Index | Key | Serves |
| --- | --- | --- |
| `by_id` | `event_id` (32 B) | `ids` filters, duplicate detection |
| `by_created_at` | `created_at`, `local_id` | filters with only `since`/`until` |
| `by_author` | `pubkey`, `created_at`, `local_id` | `authors` |
| `by_kind` | `kind`, `created_at`, `local_id` | `kinds` |
| `by_author_kind` | `pubkey`, `kind`, `created_at`, `local_id` | `authors` + `kinds` |
| `by_tag` | `tag_name` (1 B), `tag_value`, `created_at`, `local_id` | `#<letter>` |
| `by_address` | `pubkey`, `kind`, `d_value` | addressable replacement |
| `by_replaceable` | `pubkey`, `kind` | replaceable replacement |
| `by_expiration` | `expires_at`, `local_id` | NIP-40 reaper |
| `deleted` | `event_id` (32 B) | NIP-09 tombstones |

`by_author_kind` is a deliberate denormalisation: the `authors` + `kinds` combination is the
single most common shape in real client traffic, and serving it from one cursor rather than
intersecting two is the difference between a scan and a seek.

### Query planning

For each filter the planner picks one index — the most selective one whose key prefix the filter
constrains — then walks it backwards from `until` (or from the end), applying the remaining
filter conditions to each candidate as a post-filter, and stops at `limit`.

Selectivity order, most selective first: `ids` → `by_author_kind` → `by_tag` → `by_author` →
`by_kind` → `by_created_at`.

Two properties matter more than raw speed:

- **Bounded work.** The scan stops at `limit`. Query latency is a function of the requested page
  size, not of the total number of stored events.
- **No full materialisation.** Results stream to the socket as the cursor advances. A large
  `REQ` must not allocate proportionally to its result set.

The cost of this design is that a filter with a very low `limit` but a very selective post-filter
can walk many index entries before finding enough matches. A scan budget caps that: after
`max_scan` entries the subscription is answered with what was found and `EOSE`, and the event is
counted in metrics.

## Kind semantics

The rules are specified in [protocol.md](protocol.md#kind-semantics). Their storage consequences:

- **Regular** events are appended. No lookup beyond duplicate detection.
- **Replaceable** events read `by_replaceable[pubkey, kind]`, compare against the incumbent using
  the `created_at` then lexically-smaller-id tie-break, and either delete the incumbent and
  insert, or reject with `duplicate:`.
- **Addressable** events do the same against `by_address[pubkey, kind, d_value]`, where a missing
  or empty `d` tag is the empty string.
- **Ephemeral** events never reach the store.

Replacement deletes the superseded event and every index entry pointing at it, inside the same
write transaction as the insert. There is no window in which both versions are queryable and no
tombstone left behind.

## Deletion (NIP-09)

A kind-5 event lists `e` and `a` tags identifying what its author wants removed. easyrelay:

1. Verifies each target was authored by the same `pubkey` as the deletion request. Targets by a
   different author are ignored silently — a deletion request is not authorisation.
2. Removes the target event and its index entries.
3. Records the target id in `deleted`, so a later re-submission of the same event is rejected
   with `blocked:` rather than silently reinstated.
4. Stores the kind-5 event itself as a regular event, so that other relays syncing from this one
   learn about the deletion.

Deletion is a request, not a guarantee, and the NIP-11 document says so.

## Expiration (NIP-40)

An event carrying `["expiration", "<unix timestamp>"]` gets an entry in `by_expiration` at
insert time. A reaper task wakes on an interval, opens a write transaction, walks
`by_expiration` from the beginning up to `now`, and removes what it finds.

Expired events are also filtered at query time, so an event is never served between its
expiration timestamp and the next reaper pass. An `expiration` tag already in the past is
rejected at admission with `invalid:`.

## Retention

Beyond NIP-40, an operator may configure retention policies: a global maximum age, per-kind
maximum age, and a maximum event count. Enforcement runs on the same reaper task, oldest-first
via `by_created_at`. Retention policy is advertised in the NIP-11 `retention` field.

Retention is off by default. A relay that silently discards data the operator expected to keep
is worse than one that fills its disk visibly.

## Operational properties

**Map size.** LMDB requires the maximum database size up front, and it is not a reservation of
disk — it is address space. Set it generously; the file grows on demand. Running out is a hard
failure, so easyrelay logs a warning as the store crosses configurable fill thresholds and
exposes the ratio as a metric.

**Free-space reclamation.** LMDB reuses pages freed by deletions rather than shrinking the file.
A store that has had a large expiration sweep will not get smaller on disk. Reclaiming that
space requires a compaction pass, which [operations.md](operations.md) documents.

**Long read transactions pin pages.** A reader holds the snapshot it started with, so a slow
subscriber draining a huge query stops the writer from reusing freed pages and grows the file.
This is the mechanism behind the bounded-scan and streaming rules above; they are correctness
requirements for the storage engine, not query-performance tuning.

**Durability.** The default is durable: LMDB commits with metadata sync. Faster non-durable
modes exist and may be exposed as configuration, but they are never the default and never the
basis of a published benchmark. See [testing.md](testing.md#benchmarks).

**Backup.** The data directory can be copied while the relay runs, using LMDB's consistent
snapshot, without stopping writes. Procedure in [operations.md](operations.md).

## References

- [strfry](https://github.com/hoytech/strfry) — the index design this follows
- [nostrdb](https://github.com/damus-io/nostrdb) — the same design as an embeddable library
- [LMDB documentation](http://www.lmdb.tech/doc/)
