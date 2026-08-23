# 0007. Configuration file format

- **Status:** Proposed — decided in Phase 2
- **Date:** 2026-08-23

## Context

easyrelay needs an operator-facing configuration file. The candidates are ZON, Zig's native
object notation, parseable with `std.zon` in 0.16 with no dependency; and TOML, which is what
relay operators are used to and what comparable software ships.

This decision is deliberately left open. It is cheap to make late — the settings in
[configuration.md](../configuration.md) are stable and format-independent — and it benefits from
Phase 2 experience of what the file actually looks like once every setting is real.

## Decision

**Proposed:** ZON, with environment-variable overrides for containerised deployments.

Not accepted. Phase 2 closes this record.

## Consequences

If ZON is chosen: no dependency, native parsing and validation, and the same syntax contributors
already read in `build.zig.zon`. Against that, operators meet a syntax they have never seen,
every example in every blog post about relay configuration becomes unhelpful, and the format is
unfamiliar enough that a misplaced comma will generate support questions.

If TOML is chosen: operators are immediately at home and existing tooling works, at the cost of
a third-party parser in the dependency graph and its ongoing 0.16-compatibility burden.

Either way, environment-variable overrides are provided, configuration is validated in full at
startup, and an unknown key is a startup failure rather than a silently ignored line. Those
properties do not depend on the format.

## Alternatives considered

**JSON.** Universally understood and parseable with `std.json`. Rejected: no comments, which is
disqualifying for a file an operator maintains by hand and annotates.

**YAML.** Familiar and comment-friendly. Rejected: no mature Zig parser, and the specification's
size and ambiguity are a poor match for a configuration file that must fail loudly on anything
unexpected.

**Command-line flags only.** Rejected. The settings surface in
[configuration.md](../configuration.md) is far too large.

## Revisit when

Phase 2 implements configuration loading. This record moves to Accepted or is superseded then.
