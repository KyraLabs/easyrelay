# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, minor
versions may contain breaking changes; they will always be listed under `Changed` or
`Removed` with a migration note.

## [Unreleased]

### Added

- Project scaffold: `build.zig`, pinned Zig toolchain, and a command-line entry point that
  reports its version and refuses unknown arguments.
- The two runtime dependencies, pinned and compiled from source: `zig-nostr/nostr` for the
  event model, canonical serialization and Schnorr verification, and `websocket.zig` for the
  transport.
- Continuous integration: formatting gate, toolchain-pin consistency check, native tests on
  Linux and macOS, and cross-compilation of every published release target.
- Release automation producing static Linux binaries and macOS binaries with checksums.
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
