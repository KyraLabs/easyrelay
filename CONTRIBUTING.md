# Contributing

easyrelay is pre-alpha and under active design. Contributions are welcome, with the caveat that
the architecture is still settling and large changes are best discussed in an issue before they
are written.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Found a security
problem? Do not open an issue — follow the [security policy](SECURITY.md).

## Before you start

Read [docs/overview.md](docs/overview.md) for what this project is and is not, and
[docs/roadmap.md](docs/roadmap.md) for what is being built now. Work that belongs to a later
phase is usually deferred rather than declined — not because it is bad, but because the phase
before it has to land first. Deliberate [non-goals](docs/overview.md#non-goals) are declined.

## Setup

```bash
git clone https://github.com/KyraLabs/easyrelay.git
cd easyrelay
mise install     # installs the pinned Zig; see docs/development.md if you do not use mise
zig build test
```

Zig `0.16.0`, exactly. The version is a pin, not a minimum
([ADR-0001](docs/adr/0001-language-and-toolchain.md)), and it lives in three files that
`./scripts/check-toolchain.sh` keeps in agreement.

[docs/development.md](docs/development.md) has the full command list and the code conventions.

[CLAUDE.md](CLAUDE.md) is the same ground rules written for AI coding agents, plus the Zig 0.16
API changes that trip up anything trained on older Zig. It is worth a read even if you never use
one — it is the densest summary of the project's conventions.

## Before you open a pull request

Run what CI runs:

```bash
zig fmt --check .
zig build test
./scripts/check-toolchain.sh
```

CI additionally runs the tests natively on Linux and macOS and cross-compiles every published
release target, so a change that only builds on your platform will be caught there.

## Pull requests

- One logical change per pull request.
- New behaviour comes with tests. Protocol behaviour comes with a conformance test named after
  the rule it checks, written from the NIP text rather than from the implementation.
- A change to how the relay behaves on the wire updates [docs/protocol.md](docs/protocol.md) in
  the same pull request.
- A change to a NIP's status updates [docs/nips.md](docs/nips.md) in the commit that makes its
  tests pass. The NIP-11 document is generated from that table, so this is what stops the relay
  advertising something it does not do.
- A new dependency, or a change to an architectural decision, comes with an ADR. Use
  [docs/adr/0000-template.md](docs/adr/0000-template.md). Dependencies are expensive in a
  pre-1.0 language ecosystem and the cost belongs in a written decision.
- If implementation shows a documented decision was wrong, amend the ADR in the same pull
  request. A stale ADR is worse than none, because it will be trusted.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org), in English. Scope is the module.

```
feat(storage): add addressable event index
fix(relay): reject filters with non-hex author values
docs(adr): amend 0004 after the transport spike
test(conformance): cover replaceable tie-break by id
```

Pull requests are squash-merged, so **the pull request title becomes the commit message** and
is validated by CI against this format. Explain why in the body when the diff does not make it
obvious.

## Code review

Reviews focus on protocol correctness, memory ownership, and behaviour under untrusted input,
in that order. Expect questions about what happens when a client sends the malformed version of
whatever you added — that is the relay's entire threat surface.

## Scope discipline

Do not refactor code unrelated to your change. Do not add, remove or upgrade a dependency in a
pull request that is about something else. Both make review harder and bisection worse.

## Licence

Contributions are licensed under the [MIT Licence](LICENSE), the same terms as the project.
There is no CLA.
