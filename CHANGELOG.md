# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, minor
versions may contain breaking changes; they will always be listed under `Changed` or
`Removed` with a migration note.

## [Unreleased]

### Fixed

- Queries no longer fail once more than 126 connections have each queried: LMDB reader slots
  were bound to connection threads for their whole life.

### Added

- A working relay: `easyrelay` with no arguments and no configuration file serves NIP-01 over
  WebSocket on `ws://127.0.0.1:7777`. It accepts and validates events, answers subscriptions
  from stored events, and fans accepted events out live to every matching subscription.
- Persistence: events are stored in LMDB under `./data` and survive a restart. Writes go through
  a single writer thread that commits them in batches; a full queue is answered with
  `rate-limited:`.
- Kind semantics: replaceable, addressable and ephemeral events, with the NIP-01 tie-break.
- NIP-09 deletion, author-scoped, with tombstones that refuse a deleted event sent again.
- Indexed queries: each filter is planned onto the most selective index, bounded by its own
  `limit` and by `storage.max_scan`.
- Configuration: an optional `easyrelay.zon` file, `EASYRELAY_*` environment overrides,
  validation that names the offending setting, and `easyrelay init` to print every default.
- Project scaffold: `build.zig`, pinned Zig toolchain, and a command-line entry point that
  reports its version and refuses unknown arguments.
- The runtime dependencies, pinned and compiled from source: `zig-nostr/nostr` for the event
  model, canonical serialization and Schnorr verification, and `zig-lmdb` for LMDB.
- A first-party RFC 6455 WebSocket transport, which also answers plain HTTP on the same port.
- NIP-11: the relay information document, served on `Accept: application/nostr+json`.
- A conformance suite that drives the relay over a real WebSocket connection, and an interop
  check in CI that publishes an event with [`nak`](https://github.com/fiatjaf/nak) and reads it
  back.
- Continuous integration: formatting gate, toolchain-pin consistency check, native tests on
  Linux and macOS, and cross-compilation of every published release target.
- Release automation producing static Linux binaries and macOS binaries with checksums.
- NIP-40 expiration: an expired event is refused, hidden from queries the moment it expires, and
  removed by a sweep every `storage.reaper_interval_s`.
- NIP-42 authentication, which `policy.auth_required_for_write` and `auth_required_for_read`
  can require, and NIP-70 protected events.
- Rate limits per connection (events, messages, `REQ`s) and per author, all configurable.
- Admission policy: allow and deny lists by author and by kind, answered with `blocked:`.
- Backpressure: a client that does not read what it subscribed to is disconnected at
  `network.write_buffer_limit` instead of stalling other clients; pings and an idle timeout.
- Graceful shutdown on SIGTERM and SIGINT: connections close, queued events are committed.
- Structured logs, JSON or text, with a number per connection; Prometheus metrics on
  `GET /metrics` and `GET /health`.
- Design documentation: architecture, protocol contract, storage model, NIP coverage,
  configuration reference, operations runbook, test strategy, and nine architecture decision
  records.
- Community documentation: contributing guide, security policy, and code of conduct.
- Dependabot updates for GitHub Actions, grouped and titled to satisfy the Conventional
  Commits check.
- Phase 0 validation spike: a written go/no-go on the storage and transport dependencies, with
  measurements, and the documentation corrections it forced.
- `CLAUDE.md`: conventions for AI coding agents, covering the Zig 0.16 API changes, allocator
  and assertion discipline for a service handling untrusted input, and the measurement rules.

[Unreleased]: https://github.com/KyraLabs/easyrelay/commits/main
