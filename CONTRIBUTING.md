# Contributing

easyrelay is pre-alpha and under active design. Contributions are welcome, with the caveat that
the architecture is still settling and large changes are best discussed before they are written.

## Before you start

Read [docs/overview.md](docs/overview.md) for what this project is and is not, and
[docs/roadmap.md](docs/roadmap.md) for what is being built now. Work that belongs to a later
phase is likely to be declined, not because it is bad but because the phase before it has to
land first.

Set up your toolchain from [docs/development.md](docs/development.md). Zig `0.16.0`, exactly.

## Opening an issue

For a bug, include the easyrelay version, the Zig version, the configuration that reproduces it,
and the exact client messages exchanged. For a protocol bug, quote the NIP text you believe is
being violated.

For a feature, say which roadmap phase you think it belongs to. If it fits none of them, explain
why it should exist at all — [docs/overview.md](docs/overview.md) lists deliberate non-goals.

## Pull requests

- One logical change per pull request.
- `zig fmt --check .` and `zig build test` pass.
- New behaviour comes with tests. Protocol behaviour comes with a conformance test named after
  the rule it checks, written from the NIP text.
- A change to how the relay behaves on the wire updates [docs/protocol.md](docs/protocol.md) in
  the same pull request.
- A change to a NIP's status updates [docs/nips.md](docs/nips.md) in the commit that makes its
  tests pass.
- A new dependency, or a change to an architectural decision, comes with an ADR. See
  [docs/adr/0000-template.md](docs/adr/0000-template.md).

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org). Scope is the module.

```
feat(storage): add addressable event index
fix(relay): reject filters with non-hex author values
docs(adr): amend 0004 after the transport spike
test(conformance): cover replaceable tie-break by id
```

Write in English. Explain why in the body when the diff does not make it obvious.

## Code review

Reviews focus on protocol correctness, memory ownership, and behaviour under untrusted input, in
that order. Expect questions about what happens when a client sends the malformed version of
whatever you added.

## Scope discipline

Do not refactor code unrelated to your change. Do not add, remove or upgrade a dependency in a
pull request that is about something else. Both make review harder and bisection worse.
