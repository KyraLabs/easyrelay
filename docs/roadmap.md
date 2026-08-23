# Roadmap

Seven phases. Each lists its deliverables and its **exit criteria** — the checks that must pass
before the phase is considered done. A phase is not closed because its work looks finished; it
is closed because its criteria hold.

Phases are sequential. The only parallelism worth taking is writing conformance tests for a
later phase while an earlier one is being implemented, since the tests derive from
[protocol.md](protocol.md) and not from the code.

| Phase | Theme | Delivers |
| --- | --- | --- |
| [0](#phase-0--foundation-and-validation-spike) | Foundation and validation spike | A building, tested skeleton and a go/no-go on the core dependency |
| [1](#phase-1--nip-01-in-memory) | NIP-01 in memory | A relay that real clients can talk to |
| [2](#phase-2--persistence-and-indexes) | Persistence and indexes | A relay that survives restarts |
| [3](#phase-3--operational-hardening) | Operational hardening | A relay that can be exposed to the internet |
| [4](#phase-4--advanced-nips) | Advanced NIPs | COUNT, PoW, search, management API |
| [5](#phase-5--negentropy-nip-77) | Negentropy (NIP-77) | Relay-to-relay set reconciliation |
| [6](#phase-6--scaling) | Scaling | Evented I/O and honest benchmarks |

**Ease of deployment is not a phase.** It is the third project goal
([overview.md](overview.md#3-it-is-trivial-to-run)) and it is delivered incrementally, with its
own deliverables and exit criteria inside Phases 1, 2 and 3. Deferring it to a polish phase at
the end is how it fails to happen, and by then the defaults it depends on have already
calcified. [ADR-0009](adr/0009-deployment-experience.md) fixes what it commits to.

---

## Phase 0 — Foundation and validation spike

The purpose of this phase is to find out whether the plan's central bet is sound **before**
anything is built on top of it.

### Deliverables

- `build.zig` and `build.zig.zon` with every dependency pinned to an exact release.
- `.zigversion` pinning Zig `0.16.0`, a matching `mise.toml`, and `scripts/check-toolchain.sh`
  guarding the two against `build.zig.zon`.
- A trivial `main.zig`, a test target, and `zig fmt` compliance.
- CI running format check, build and tests on every push.
- **A validation spike against `zig-nostr/nostr`**, discarded afterwards, answering:
  1. Does its LMDB store support many concurrent readers alongside a single writer thread?
  2. Does it expose deletion and expiration, or can they be built on its API?
  3. Does its query planner cover every filter shape in
     [protocol.md](protocol.md#filters), including multi-tag filters?
  4. Does its API let easyrelay own the write transaction boundary, so that insert, replacement
     and index maintenance commit atomically?
- **A second spike against `websocket.zig` on Zig 0.16**, whose upstream support is flagged as
  experimental: hold N idle connections, push messages through them, and confirm the library
  neither leaks nor drops frames.
- A written go/no-go document in `docs/research/`, recording the answers with the evidence.

### Exit criteria

- `zig build test` passes locally and in CI.
- The go/no-go document exists and reaches a verdict on each of the six questions above.
- If the store verdict is **no-go**, [ADR-0002](adr/0002-build-on-zig-nostr.md) and
  [ADR-0008](adr/0008-store-abstraction-boundary.md) are amended and Phase 2 switches to a
  first-party LMDB schema built on
  [`zig-lmdb`](https://github.com/nDimensional/zig-lmdb). **No other phase moves.** Containing
  that blast radius is the entire purpose of the `Store` boundary.
- If the transport verdict is no-go, [ADR-0004](adr/0004-websocket-transport.md) is amended and
  Phase 1 begins with a first-party RFC 6455 frame layer over `std.net`.

---

## Phase 1 — NIP-01 in memory

A relay that a real client can publish to and read from, with no persistence.

### Deliverables

- WebSocket server accepting connections and dispatching messages.
- Message codec for `EVENT`, `REQ`, `CLOSE`; emission of `EVENT`, `OK`, `EOSE`, `CLOSED`,
  `NOTICE`, with the machine-readable prefixes from
  [protocol.md](protocol.md#machine-readable-result-prefixes).
- Full event validation: structural limits, `created_at` window, canonical id recomputation,
  Schnorr verification — in that order.
- The `Store` interface and its `memory` implementation.
- Subscription registry with live fan-out to matching subscriptions.
- Conformance tests for filter semantics; official BIP-340 vectors and canonical-id vectors
  under `tests/vectors/`.
- **Runs with no arguments.** `easyrelay` with no flags and no configuration file starts and
  serves. Zero-config is established here, while the surface is small enough that it costs
  nothing, rather than retrofitted once every setting exists.

### Exit criteria

- [`nak`](https://github.com/fiatjaf/nak) publishes an event and reads it back:
  `nak event -c "hello" ws://localhost:7777` followed by `nak req -k 1 ws://localhost:7777`.
- Two connections: one subscribes, the other publishes, the first receives the event live.
- Every canonical-id and Schnorr vector passes, including events with non-ASCII content,
  embedded newlines and quotes.
- An event with a tampered id, and an event with a valid id but an invalid signature, are both
  rejected with `invalid:`.
- `EOSE` arrives after stored events and before any live event on the same subscription.
- A clean checkout builds and `./easyrelay` serves a client, with no file created or edited
  first.

---

## Phase 2 — Persistence and indexes

### Deliverables

- The `lmdb` backend behind the `Store` interface, with the data model in
  [storage.md](storage.md).
- The single-writer thread and the bounded write queue.
- Complete kind semantics: regular, replaceable, ephemeral, addressable, with the `created_at`
  then lexically-smaller-id tie-break and empty-string `d` handling.
- Bounded newest-first query planning with a scan budget.
- NIP-11 relay information document, generated from configuration and from
  [nips.md](nips.md), served on `Accept: application/nostr+json`.
- Configuration file loading, which closes [ADR-0007](adr/0007-configuration-format.md).
- **A complete default set.** Every setting in [configuration.md](configuration.md) has a
  default correct for a real deployment, not merely one that avoids a crash. Defaults are a
  correctness surface from this point on and are reviewed as such.
- **`easyrelay init`**, emitting a fully commented configuration file with every default filled
  in, so tuning starts from a complete document rather than from the reference manual.
- **Actionable startup validation.** Unknown key, out-of-range value or contradictory
  combination stops the relay with a message naming the key and the fix. No silently ignored
  lines, no stack traces.
- **A useful startup message**: the URL being served, the data directory in use, whether the
  relay is reachable only from loopback, and what to change if that is not what was wanted.

### Exit criteria

- Events published before a restart are queryable after it.
- Replaceable and addressable semantics verified by tests, including both tie-break paths and
  the three equivalent forms of an empty `d` tag.
- A superseded event is gone from the store, not merely hidden from queries.
- Ephemeral events are fanned out and never persisted.
- On a 100k-event dataset, a `limit: 500` query's latency is within a small constant factor of
  the same query against a 10k-event dataset. Flat-as-it-grows is the property being tested,
  not any absolute number.
- The NIP-11 `supported_nips` array matches [nips.md](nips.md) exactly, checked by a test.
- The relay starts and persists data with no configuration file present.
- `easyrelay init` output, fed back in unmodified, produces byte-identical behaviour to running
  with no file at all. Verified by a test, because a drifting `init` template is worse than none.
- Every configuration error path has a test asserting the message names the offending key.

---

## Phase 3 — Operational hardening

The phase that makes the relay safe to expose to the open internet.

### Deliverables

- Rate limiting per connection and per pubkey, with the write queue as the final backstop.
- Enforced structural limits from [protocol.md](protocol.md#structural-limits), all
  configurable and all advertised in NIP-11 `limitation`.
- NIP-09 event deletion with tombstones.
- NIP-40 expiration: reaper task plus query-time filtering.
- NIP-42 authentication (kind 22242), configurable to gate writes, reads, or both.
- NIP-70 protected events.
- Admission policy engine: allow and deny lists by pubkey and by kind.
- Per-connection write backpressure with disconnect rather than unbounded buffering.
- Graceful shutdown: stop accepting, drain the write queue, commit, close.
- Structured logging with levels and per-connection correlation.
- Prometheus metrics on `GET /metrics`, and `GET /health`.
- **Distribution.** Prebuilt binaries for common Linux and macOS targets, cross-compiled from
  one host — Zig makes this a build matrix rather than a CI fleet — plus a container image,
  published as release artifacts and checksummed.
- **`deploy/docker-compose.yml`**: easyrelay behind Caddy, parameterised by a single
  `RELAY_DOMAIN`, tested in CI. This is the documented default path to a public relay and the
  substance of [ADR-0009](adr/0009-deployment-experience.md).
- **A systemd unit** shipped as an artifact rather than only pasted in the documentation.
- **`easyrelay doctor`**: validates the configuration, checks the data directory is writable,
  reports map-size headroom, and states whether the relay is reachable from outside loopback.

### Exit criteria

- A load generator opening connections and flooding events degrades only its own connections;
  a concurrently connected well-behaved client sees no dropped events and no latency cliff.
- A client that stops reading while subscribed to a firehose is disconnected on its backpressure
  limit, with relay memory flat throughout.
- `SIGTERM` during sustained writes loses no acknowledged event: every event that received
  `OK true` is present after restart.
- NIP-09, NIP-40, NIP-42 and NIP-70 conformance tests pass, including a deletion request
  targeting another author's event, which must be ignored.
- The backup and restore runbook in [operations.md](operations.md) has been executed end to end
  against a running relay.
- **The timed first-run test.** Someone who has not seen the project before, given only the
  README and a domain name pointed at a fresh machine, reaches a working `wss://` relay that a
  real client connects to, in under ten minutes, without reading any other document and without
  asking a question. Run against a real person for each release, and treated as a failing test
  when it fails — the fix is the documentation or the defaults, not the tester.
- A published binary runs on a machine with no toolchain, no LMDB and no `libsecp256k1`
  installed.
- `docker compose up -d` with only `RELAY_DOMAIN` set yields a relay reachable over `wss://`
  with a valid certificate.

---

## Phase 4 — Advanced NIPs

### Deliverables

- NIP-45 `COUNT`.
- NIP-13 proof of work, validating the committed target in the `nonce` tag.
- NIP-50 search, with the full-text index it requires. The largest item in this phase.
- NIP-86 relay management API.
- External write-policy plugins: a child process exchanging JSON over stdin and stdout, in the
  style of strfry, so operators can implement admission rules without forking easyrelay.

### Exit criteria

- Conformance tests pass for each NIP above.
- `COUNT` returns the same number as the length of the corresponding `REQ` result set, verified
  across randomised filters.
- A NIP-13 event whose `nonce` tag commits to a lower difficulty than it actually achieves is
  rejected, not credited for the accidental extra work.
- The search index survives a restart and is rebuildable from the event store.
- A write-policy plugin that rejects a chosen kind is honoured, and a plugin that crashes fails
  closed rather than admitting everything.
- NIP-86 refuses unauthenticated calls.

---

## Phase 5 — Negentropy (NIP-77)

Range-based set reconciliation, so two relays can converge on a shared event set while
transferring an amount of data proportional to their difference rather than their size. No Zig
implementation exists; this is a port of the C++ reference.

### Deliverables

- MSB-first varint encoding and decoding.
- `Bound` and `Range` encoding with delta compression.
- Fingerprint computation over sorted event ranges.
- The reconciliation state machine, both as initiator and as responder.
- `NEG-OPEN`, `NEG-MSG`, `NEG-CLOSE` and `NEG-ERR` wiring.
- A sync subcommand for pulling from or pushing to another relay.
- Overflow and bounds guards on every field decoded from an untrusted peer.

### Exit criteria

- Reconciliation against `strfry sync` as the reference implementation converges correctly in
  both directions.
- Multi-round tests: disjoint sets, identical sets, one-sided differences, and sets differing by
  a single event in the middle of a range.
- Fuzzing the frame decoder over a sustained run produces no crash, no hang and no allocation
  proportional to a peer-supplied length field.
- Bandwidth for reconciling two 100k-event stores differing by 100 events is orders of magnitude
  below transferring either set.

---

## Phase 6 — Scaling

### Deliverables

- A benchmark harness in `bench/`, in the repository and reproducible by anyone.
- Migration from the thread pool to an evented runtime — `std.Io.Evented` if it has stabilised,
  otherwise [`zio`](https://github.com/lalinsky/zio) over io_uring. The `std.Io` interface is
  what makes this a backend swap rather than a rewrite; see
  [ADR-0005](adr/0005-concurrency-model.md).
- Connection sharding across cores.
- Write batching: multiple events per LMDB transaction under load.

### Exit criteria

- Published benchmarks state hardware, dataset, concurrency and durability mode, and are run in
  **durable** mode. Numbers from non-durable mode are either labelled as such or not published.
- A comparison against strfry on identical hardware with an identical dataset.
- Tens of thousands of idle connections held with memory growth per connection measured and
  documented.
- The full conformance suite passes unchanged on the evented runtime. If the migration cannot
  keep every test green, it does not ship.

---

## Ordering rationale

Ease of deployment is spread across Phases 1 to 3 rather than concentrated, because each of its
pieces depends on the phase it sits in and on nothing later. Zero-config start is free in Phase
1 and expensive to retrofit afterwards. Defaults cannot be declared correct before Phase 2 knows
what the settings are. Distribution artifacts are meaningless before Phase 3 makes the relay
safe to expose. Bolting all of it on at the end would mean shipping a relay whose defaults were
chosen when nobody was thinking about the operator.

Persistence precedes hardening because rate limits and policy are meaningless against a relay
that loses everything on restart. Hardening precedes advanced NIPs because a relay exposed to
the internet without limits is a liability regardless of how many NIPs it advertises. NIP-77
comes after all of that because it is the most complex component and the one that benefits most
from a stable, well-tested store underneath. Scaling comes last because optimising before the
conformance suite exists means having no way to tell whether an optimisation broke correctness.
