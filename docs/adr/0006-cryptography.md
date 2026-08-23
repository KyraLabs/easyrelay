# 0006. BIP-340 via `libsecp256k1`, never `std.crypto`

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

Every inbound event carries a BIP-340 Schnorr signature over secp256k1 that the relay must
verify before accepting it. This is the single most security-critical operation in the program
and also the hottest CPU path under load.

Zig's `std.crypto` provides SHA-256, which is all that is needed for event ids. It does not
provide BIP-340 Schnorr. It does expose secp256k1 curve primitives, but those have a history of
correctness bugs — [ziglang/zig#23503](https://github.com/ziglang/zig/issues/23503) is one
example — and building a signature scheme on them would mean this project owning the correctness
of a cryptographic implementation.

`libsecp256k1` from Bitcoin Core is the reference implementation, is widely audited, and is
already the choice of every Zig Nostr project examined: `zig-nostr/nostr` uses it and passes the
full official BIP-340 vector suite, and Wisp links it as well.

## Decision

Verify signatures with `libsecp256k1`, as vendored and compiled by
[`zig-nostr/nostr`](0002-build-on-zig-nostr.md). Use `std.crypto.hash.sha2.Sha256` for event
ids. **Never** use `std.crypto`'s secp256k1 primitives for signature work, and never write a
Schnorr implementation in this repository.

## Consequences

Signature verification is handled by the reference implementation, and the official vectors —
including the cases that must fail to verify — run on every build. This is not a place where a
clever local implementation would be an improvement.

Vendoring means no system `libsecp256k1` package for contributors or operators. Confirmed
relevant: the development machine for this project does not have it installed, and does not need
it.

The cost is a C dependency in the build, which lengthens a clean build. It is compiled once and
cached, and it buys correctness that is not otherwise purchasable.

Should `zig-nostr/nostr` ever be dropped, `libsecp256k1` would be vendored directly with a
`build.zig` of its own, built with `--enable-module-schnorrsig`. The decision to use
`libsecp256k1` survives independently of the decision to use `zig-nostr`.

## Alternatives considered

**Pure-Zig Schnorr on `std.crypto` primitives.** No C dependency, faster clean builds. Rejected
firmly. Signature verification is where a subtle bug becomes a security vulnerability rather
than a wrong answer, and the underlying primitives have a bug history.

**System `libsecp256k1` via `@cImport`.** Faster builds, and the distribution handles security
updates. Rejected: it puts a system package between an operator and a working binary, which
contradicts single-binary deployment. Distributions also frequently ship builds without the
`schnorrsig` module enabled.

**`jsign/zig-eth-secp256k1`.** An existing Zig wrapper, but oriented to Ethereum's ECDSA needs
rather than BIP-340. No advantage over what `zig-nostr` already provides.

## Revisit when

`std.crypto` ships an audited BIP-340 implementation, which would remove the C dependency for a
security-relevant path — worth a serious look at that point, and not before.
