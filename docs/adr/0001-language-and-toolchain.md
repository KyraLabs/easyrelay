# 0001. Zig 0.16.0 with a pinned toolchain

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

easyrelay is written in Zig. That choice follows from what a relay needs: no garbage collector,
so latency is predictable under load; manual memory control, so an adversarial client cannot
provoke unbounded allocation; trivial C interoperability, which is what makes `libsecp256k1` and
LMDB usable without binding layers; and a single static binary, which is the whole deployment
story.

The complication is that Zig is not 1.0 and every release breaks something. Version 0.16.0,
released 14 April 2026, is the current stable, and it is a disruptive one: it introduced
`std.Io` as an interface, removed `GenericReader`, `AnyReader` and `FixedBufferStream`, and
withdrew much of the OS-specific `std.posix` surface. Projects the size of ghostty needed real
migration work.

Verified locally: `zig version` reports `0.16.0`.

## Decision

Target Zig `0.16.0` exactly. Pin it in `.zigversion`, install it through mise, and have CI use
that same file as the source of truth.

The version is a pin, not a minimum. Compiler upgrades are deliberate work with their own pull
request, not something that happens because a contributor has a newer toolchain.

## Consequences

Every contributor and CI run compiles with the same compiler, so a build failure is a code
problem rather than an environment problem.

Dependencies must support 0.16. This is satisfiable today — `zig-nostr/nostr` pins 0.16.0,
`zig-lmdb` has a 0.16 release, and `websocket.zig` supports it on `master` — but it does
constrain what can be adopted.

Upgrading to 0.17 will be a project, not a bump, and it will be scheduled as one. The cost is
paid once per release rather than continuously.

Being pre-1.0 also means the standard library can change under us. The `std.Io` migration in
0.16 is precisely the kind of change to expect again.

## Alternatives considered

**Rust.** A mature ecosystem, a 1.0 language, and two production relays already written in it
(nostr-rs-relay, rnostr). Rejected because it does not serve the goal: those relays exist and
work, and a third would be redundant. Zig's C interoperability and explicit allocation are also
a better fit for a program whose main job is parsing untrusted bytes into a memory-mapped store.

**Zig nightly.** Access to fixes and to a stabilising `std.Io` sooner. Rejected: a moving
compiler on a project this young turns every unrelated pull request into a potential toolchain
debugging session.

**Zig 0.15.x.** More settled and better supported by libraries at the time. Rejected because
`std.Io` is the mechanism that makes the Phase 6 thread-pool-to-evented migration a backend swap
instead of a rewrite. Starting on 0.15 means paying for that migration twice.

## Revisit when

Zig 0.17.0 is released and the dependency set supports it, or when 1.0 is announced.
