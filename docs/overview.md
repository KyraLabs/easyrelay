# Overview

## What easyrelay is

easyrelay is a Nostr relay implementation in Zig, aimed at production deployment.

A relay is a small, well-defined thing: a WebSocket server that accepts signed events, stores
them, and streams back the ones matching a subscriber's filters. The difficulty is not in the
protocol; it is in doing this correctly and predictably while adversarial clients push events
at it, while the store grows past the point where naive queries stop being fast, and while the
operator needs to back it up, observe it, and restart it without losing data.

easyrelay optimises for that second set of problems.

## Goals

**Single-binary deployment.** No external database, no runtime, no interpreter. The operator
copies one binary and one configuration file to a machine and runs it. LMDB is embedded;
`libsecp256k1` is statically linked.

**Correctness before speed.** An event id computed from a non-canonical serialization, or a
replaceable event resolved with the wrong tie-break, makes the relay silently incompatible with
the network. Every rule in [protocol.md](protocol.md) is backed by a conformance test before
any optimisation work is considered.

**Predictable resource use.** No garbage collector, no unbounded queues, explicit limits on
event size, tag count, subscription count and per-connection buffering. A relay that degrades
gracefully under abuse is worth more than one with a better benchmark.

**Complete NIP coverage for a serious relay.** The target set is NIP-01, 09, 11, 13, 40, 42,
45, 50, 65, 70, 77 and 86. See [nips.md](nips.md).

**Honest performance reporting.** Benchmarks are published only in durable write mode, on
stated hardware, against a named reference implementation, with the harness in the repository.
Numbers taken with durability disabled are labelled as such or not published at all.

## Non-goals

**Not a Nostr client, and not a client library.** Client-side concerns — key management,
signing, the outbox model, NIP-46 remote signing — belong to `zig-nostr/nostr`, which easyrelay
consumes. easyrelay never holds a user's private key. It holds one relay identity key at most,
for NIP-11 and NIP-86.

**Not a paid-relay platform.** Payment processing, invoicing and subscription billing are out
of scope. The admission policy layer is extensible enough that an operator can implement paid
access through an external write-policy plugin, but easyrelay ships no payment integration.

**Not TLS-terminating.** Certificates, renewal and HTTP/2 are a reverse proxy's job. easyrelay
speaks plaintext WebSocket behind Caddy or nginx. See [operations.md](operations.md).

**Not a general-purpose database.** The query surface is exactly the NIP-01 filter language.
There is no SQL, no ad-hoc query planner, and no plan to add one.

## Who this is for

The primary operator is someone running a relay that other people depend on: a community
relay, a team relay, or a public relay carrying meaningful traffic. They are comfortable with a
reverse proxy and a systemd unit, they scrape Prometheus, and they will notice if restarts lose
data or if p99 latency drifts.

A second, smaller audience is the operator of a personal relay who wants the same software
without tuning anything. Defaults are chosen so that this case works with an almost empty
configuration file.

## Relationship to existing work

The relevant prior art, and what easyrelay takes from each:

- **strfry** (C++, LMDB) is the architectural model: custom indexes over LMDB instead of a SQL
  engine, a single writer thread, and Negentropy-based relay-to-relay sync. The storage design
  in [storage.md](storage.md) follows it.
- **nostrdb** (C, LMDB) demonstrates the same index design as an embeddable library, and is the
  model `zig-nostr/nostr`'s store follows.
- **Wisp** (Zig, LMDB) is proof that a complete relay in Zig is achievable, and a useful map of
  the dependency surface.
- **`zig-nostr/nostr`** is a direct dependency rather than a reference. See
  [ADR-0002](adr/0002-build-on-zig-nostr.md).

easyrelay differs from Wisp in one deliberate way: it does not reimplement the protocol layer.
That work exists, is tested against the official BIP-340 vectors, and is better shared than
duplicated. The corresponding risk is documented in [ADR-0002](adr/0002-build-on-zig-nostr.md)
and contained by the boundary in [ADR-0008](adr/0008-store-abstraction-boundary.md).

## Current state

Documentation only. Phase 0 of the [roadmap](roadmap.md) delivers the first executable code.
