# 0004. `websocket.zig` as the transport

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

Nostr runs over WebSocket. Zig's standard library ships an HTTP server but no complete
server-side WebSocket implementation, so this is a dependency or a first-party frame layer.

Verified against upstream:
[`websocket.zig`](https://github.com/karlseguin/websocket.zig) supports Zig 0.16 on `master`,
with the README stating plainly that "this ZIG 0.16 version is not well tested. Like Zig 0.16
itself, consider this experimental!". It is the de facto choice in the ecosystem, is
non-blocking on Linux, macOS and BSD, and guarantees that a single connection's messages are
processed one at a time. The 0.16 API is `ws.Server(Handler).init(io, allocator, .{...})`
followed by `listen(&app)`, with the handler providing `init` and `clientMessage`.

## Decision

Use `websocket.zig`, accepting its experimental 0.16 status, and validate it with a dedicated
spike in Phase 0 before any relay logic is built on it.

## Consequences

The RFC 6455 frame layer, the handshake, fragmentation, masking and ping/pong come for free.
That is a meaningful amount of fiddly, security-relevant code not written here.

The one-message-at-a-time guarantee removes per-connection locking from every layer above the
transport, which simplifies the subscription registry considerably.

The library taking an `Io` parameter aligns with [ADR-0005](0005-concurrency-model.md): the
transport does not hard-code the threaded backend, so the Phase 6 migration to an evented
runtime is a change of what is passed in rather than a change of transport.

Against that, the project is depending on a component its own authors label experimental on this
compiler version. The Phase 0 spike exists for exactly this reason, and it has a defined
fallback: if the library proves unreliable, Phase 1 begins with a first-party frame layer over
`std.net`. Discovering this in Phase 0 costs days; discovering it in Phase 3 costs the schedule.

## Alternatives considered

**`zap`** (a wrapper over the C facil.io). Robust and fast, but pinned to Zig 0.13 with no
Windows support. Incompatible with [ADR-0001](0001-language-and-toolchain.md).

**A first-party frame layer over `std.net`.** No dependency and no upstream risk, and RFC 6455
is not a large specification. Rejected as the starting point because it delays NIP-01 by weeks
of work that is not what makes this relay worth building. Retained as the documented fallback.

**`std.http`.** No complete server-side WebSocket support. Not an option.

## Outcome of the Phase 0 spike (2026-08-23)

**Go.** The library compiled against Zig 0.16 on the first attempt despite its experimental
label, held **3000 concurrent connections**, and echoed every message byte-for-byte and in order
across roughly 13,000 connection lifecycles — zero dropped frames, zero corrupted frames, zero
failed connections. Memory tracks peak concurrency rather than connections served, settling at
about 3 KB per connection and staying flat once the high-water mark is reached.

The fallback this record kept in reserve — a first-party RFC 6455 layer — stays unused.

One caveat the spike did not clear: it exercised the happy path at scale, not malformed frames,
hostile fragmentation, slow-loris handshakes, or a stalled reader. Those are Phase 3 work and
are where an experimental transport is most likely to disappoint. The fallback is not deleted
until they pass.

## What Phase 1 found (2026-08-24)

Building the relay on it surfaced two lifecycle bugs the Phase 0 spike could not have seen,
because that spike never closed connections while the server was shutting down.

**`close` is not called exactly once.** The readme guarantees that it is. Two paths call the
handler's `close` and they take different locks: the cleanup path releases the per-connection
lock *before* calling it, while the shutdown path calls it *holding* that lock. A client
disconnecting as the server stops reaches both, and easyrelay's handler then frees that
connection's subscriptions twice. `std.testing.allocator` caught it as a double free.
easyrelay's `close` is idempotent through an atomic exchange, which is cheap insurance whatever
upstream decides.

**Shutdown races with the thread pool.** Stopping the server while a connection is still being
torn down lets one thread free a connection's state while a pool thread is still inside that
connection's `close`, which faults. easyrelay's tests drain first — wait until every connection
is gone, then stop — which is what Phase 3's graceful shutdown has to do for real anyway.

Neither changes the decision. Both are in the shutdown path, both are contained by a few lines
here, and the first-party frame layer this record keeps in reserve would still cost weeks. Both
are worth reporting upstream. What they do change is the weight of Phase 3's adversarial
testing: this class of bug is where an experimental transport was always most likely to
disappoint, and it has now disappointed once before that phase started.

## Revisit when

Phase 3's adversarial transport tests report, or `websocket.zig` marks its 0.16 support stable,
or the Phase 6 migration finds it incompatible with the evented runtime.
