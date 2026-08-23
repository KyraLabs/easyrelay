# 0005. Thread pool now, evented runtime in Phase 6

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

A relay holds many mostly-idle connections. Handling tens of thousands of them eventually
requires an evented runtime; handling hundreds does not.

Zig 0.16 introduced `std.Io` as an interface, passed explicitly like an `Allocator`, which
removes function colouring. Two backends exist: `Io.Threaded`, a thread pool, which is
feature-complete; and `Io.Evented`, built on io_uring and GCD, which is experimental in this
release. [`zio`](https://github.com/lalinsky/zio) is a third-party M:N coroutine runtime over
io_uring, epoll and kqueue that also implements `std.Io`.

Independently, LMDB permits one write transaction at a time, process-wide. That constraint
exists regardless of the I/O model.

## Decision

Ship on the threaded backend. Structure all I/O against the `std.Io` interface so the backend is
a parameter rather than an assumption. Serialise all writes through a single writer thread fed
by a bounded queue. Defer the evented migration to Phase 6.

## Consequences

The threaded backend is the only feature-complete option in 0.16, so the project is not building
on an experimental foundation for its core loop — a risk it is already carrying in the transport
([ADR-0004](0004-websocket-transport.md)) and does not need twice.

Writing against `std.Io` makes Phase 6 a change of what is passed in. Both `Io.Evented` and
`zio` implement the same interface, so the choice between them can be made later, on evidence,
rather than guessed now.

The single writer is not a temporary simplification. It is what LMDB requires, and it is what
strfry does. Removing it later is not on the roadmap because it is not possible.

The ceiling is real: one thread per connection does not reach tens of thousands of connections.
Phase 6 exists for that, and Phase 6's exit criteria require the full conformance suite to pass
unchanged on the new backend.

The bounded write queue makes backpressure explicit. When it fills, clients get `rate-limited:`
rather than an unbounded queue absorbing the load until memory runs out. This is a better
failure mode and it is available from Phase 2, not Phase 6.

## Alternatives considered

**Adopt `zio` immediately.** io_uring scalability from the start, and it implements `std.Io`, so
it is not an architectural fork. Rejected on risk stacking: an experimental transport on top of a
young runtime on top of a pre-1.0 compiler, with no conformance suite yet to tell which layer
broke. The whole point of writing against `std.Io` is that this option stays open at no cost.

**`Io.Evented` immediately.** Same reasoning, and it is explicitly experimental in 0.16.

**Thread per connection, no pool.** Simplest possible model. Rejected: the memory and scheduling
cost per connection makes even a mid-sized relay expensive, and it buys nothing over a pool.

**Multiple writer threads.** Not possible. LMDB's write lock is process-wide.

## Revisit when

Phase 6 begins, or `Io.Evented` is marked stable in a Zig release, or measured connection counts
approach the thread pool's practical ceiling before Phase 6 is due.
