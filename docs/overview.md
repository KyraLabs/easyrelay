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

Three goals, in priority order. They mostly reinforce each other; where they genuinely conflict,
the earlier one wins.

### 1. It works

**Correctness before speed.** An event id computed from a non-canonical serialization, or a
replaceable event resolved with the wrong tie-break, makes the relay silently incompatible with
the network — it will look healthy while clients quietly discard everything it serves. Every
rule in [protocol.md](protocol.md) is backed by a conformance test before any optimisation work
is considered.

**Complete NIP coverage for a serious relay.** The target set is NIP-01, 09, 11, 13, 40, 42,
45, 50, 65, 70, 77 and 86. See [nips.md](nips.md). A NIP is advertised in the relay's NIP-11
document only once its conformance suite passes, so the advertised list cannot drift ahead of
reality.

### 2. It is fast

**Bounded query cost.** Hand-built indexes over a memory-mapped LMDB store, zero-copy reads, and
a planner whose work is a function of the requested page size rather than of the total number of
stored events. The property being engineered for is that latency stays flat as the relay ages,
which matters more in practice than any peak throughput figure.

**Predictable resource use.** No garbage collector, no unbounded queues, explicit limits on
event size, tag count, subscription count and per-connection buffering. A relay that degrades
gracefully under abuse is worth more than one with a better benchmark.

**Honest performance reporting.** Benchmarks are published only in durable write mode, on
stated hardware, against a named reference implementation, with the harness in the repository.
Numbers taken with durability disabled are labelled as such or not published at all.

### 3. It is trivial to run

This is what the name refers to, and it is a feature with its own deliverables and its own exit
criteria in the [roadmap](roadmap.md) — not a side effect of compiling to a static binary. The
commitments are specific enough to fail:

**Zero configuration to start.** `easyrelay` with no arguments and no configuration file starts
a working relay. Every setting has a default that is correct for a real deployment, not merely
one that avoids a crash.

**Nothing to install alongside it.** No database server, no runtime, no interpreter, no system
package. LMDB and `libsecp256k1` are compiled into the binary. Prebuilt binaries are published
for common platforms, and a container image alongside them.

**One command to a public relay.** A bundled compose file brings up easyrelay behind a proxy
that obtains its own TLS certificate. Standing up a relay on the internet should not require
learning a reverse proxy first. See [ADR-0009](adr/0009-deployment-experience.md).

**Errors that tell you what to do.** Configuration is validated in full at startup. An unknown
key, an out-of-range value or a contradictory combination stops the relay with a message naming
the key and the fix — never a silently ignored line and never a stack trace.

**Upgrades are: replace the binary.** No migration command in the normal case, and release notes
that state plainly when that is not true.

### The tension worth naming

Goal 3 pulls against goal 2 in exactly one place: durability and safety defaults cost
throughput, and defaults that make a first run pleasant are not always the defaults that make a
public relay safe. easyrelay resolves this by defaulting to the safe choice and making the fast
choice explicit — `storage.durable` is on, the relay binds to loopback, and rate limits are
active out of the box. Easy means the default path works and is honest about what it is doing,
not that the defaults are tuned for a benchmark.

## Non-goals

**Not a Nostr client, and not a client library.** Client-side concerns — key management,
signing, the outbox model, NIP-46 remote signing — belong to `zig-nostr/nostr`, which easyrelay
consumes. easyrelay never holds a user's private key. It holds one relay identity key at most,
for NIP-11 and NIP-86.

**Not a paid-relay platform.** Payment processing, invoicing and subscription billing are out
of scope. The admission policy layer is extensible enough that an operator can implement paid
access through an external write-policy plugin, but easyrelay ships no payment integration.

**Not TLS-terminating.** Certificates, renewal and HTTP/2 are a reverse proxy's job, and a
proxy does that job better than a relay would. This does not push the work onto the operator:
the bundled compose file in [operations.md](operations.md) runs the proxy for you and is the
documented default path. The reasoning, and the condition under which built-in ACME would be
reconsidered, are in [ADR-0009](adr/0009-deployment-experience.md).

**Not a general-purpose database.** The query surface is exactly the NIP-01 filter language.
There is no SQL, no ad-hoc query planner, and no plan to add one.

## Who this is for

**Someone who wants a relay running today.** They are technical but they are not looking to
become a relay expert. They want to run one command, get a working relay, and move on. They
should never need to read [configuration.md](configuration.md) to succeed. This audience is the
reason goal 3 exists, and the reason the default path is measured in the roadmap's exit
criteria rather than assumed.

**Someone running a relay other people depend on.** A community relay, a team relay, or a public
relay carrying meaningful traffic. They are comfortable with a systemd unit, they scrape
Prometheus, and they will notice if a restart loses data or if p99 latency drifts. They need
every setting in [configuration.md](configuration.md) and every metric in
[operations.md](operations.md).

The same binary serves both. The first audience gets there by touching nothing; the second gets
there by touching what they need. What must not happen is the common failure where making the
simple case easy quietly caps what the serious case can do.

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
