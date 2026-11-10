# 0011. A first-party WebSocket transport

- **Status:** Accepted
- **Date:** 2026-11-10
- **Deciders:** maintainer

## Context

[ADR-0004](0004-websocket-transport.md) took `websocket.zig` and kept a first-party RFC 6455
layer as the documented fallback, to be used if the library proved unreliable.

Phase 2 needs the relay to answer a plain HTTP request on its WebSocket listener: NIP-11 serves
the relay information document from the same URL, to a `GET` carrying
`Accept: application/nostr+json`. Phase 3 needs the same for `GET /health` and `GET /metrics`.
Reading `websocket.zig` at the pinned commit shows that a request which is not a WebSocket
upgrade is answered with a 400 while the handshake is parsed, before any application code runs,
and that nothing in its API lets the application intervene. Its one related hook,
`handshakeErrorResponse`, is reached only when the handler's `init` fails, and calls
`preHandOffWrite` with one argument where two are required, so it does not compile when used.

Keeping the library therefore means carrying a patch: a fork pinned in `build.zig.zon`, or a
vendored copy. Either way the relay depends on a component its authors label experimental on
Zig 0.16, whose lifecycle already surprised Phase 1 twice (ADR-0004, "What Phase 1 found"), and
whose adversarial behaviour — malformed frames, hostile fragmentation, slow-loris handshakes, a
stalled reader — Phase 3 has yet to test.

## Decision

easyrelay implements its own RFC 6455 server transport in `src/transport/`, over `std.Io.net`,
and drops the `websocket.zig` dependency. This supersedes the library choice in ADR-0004; the
concurrency model of [ADR-0005](0005-concurrency-model.md) is unchanged.

The specifics:

- **One thread per connection**, blocking reads, bounded by `network.max_connections`. ADR-0005
  already accepts this ceiling until Phase 6.
- **Every resource bounded**: the handshake request size, the handshake time (a receive
  timeout on the socket), the frame payload and the assembled message size
  (`limits.max_message_size`).
- **Only what a relay needs**: text and binary messages, fragmentation, ping, pong and close.
  No extensions; `permessage-deflate` is not negotiated.
- **A request that is not an upgrade** is offered to the application before it is refused, which
  is the hook NIP-11, health and metrics need.
- **The frame decoder is a fuzz target**, as [testing.md](../testing.md) requires for every
  decoder of untrusted bytes.

## Consequences

Plain HTTP answers on the relay's listener become ordinary code rather than a patch to someone
else's. The transport's lifecycle is ours to specify, so `close` runs exactly once by
construction and shutdown has no thread-pool race to drain around.

We own fiddly, security-relevant code: masking, fragmentation, control frames interleaved with
data, close handshakes, UTF-8 validation of text frames. ADR-0004 named this as the reason to
take a library. It is now the work Phase 3's adversarial transport testing exercises against our
code instead of a dependency's.

The listener sets `SO_REUSEADDR` so a restart is not refused by connections in TIME_WAIT, and
`std.Io.net` sets `SO_REUSEPORT` with it; a second relay started on the same port is therefore
not refused either, and shares the traffic.

One thread per connection costs a stack per connection. It is the ceiling ADR-0005 already
records, and the reason Phase 6 exists.

The conformance harness loses its WebSocket client with the dependency, so the tests gain a
minimal client of their own. It is test code, but it is also a second implementation of the
framing, which is what makes a codec bug visible rather than self-consistent.

## Alternatives considered

**Fork `websocket.zig` and pin the fork.** A seven-line patch, with an upstream pull request.
Rejected by the maintainer: it keeps the relay on a dependency it has to patch to serve a
document NIP-11 requires, and on a fork whose upkeep is ours either way.

**Vendor `websocket.zig` with the patch.** No external account or fork, and a small diff today.
Rejected for the same reason: the code becomes ours to maintain without having been written to
our constraints, and the adversarial testing Phase 3 requires would be testing code we do not
know.

**Serve NIP-11 on a second port.** Contradicts NIP-11, which serves the document at the relay's
own URL.

## Revisit when

Zig's standard library gains a complete server-side WebSocket implementation, or measurements in
Phase 6 show the transport, rather than the store, bounding throughput.
