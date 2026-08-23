# Security policy

easyrelay verifies cryptographic signatures and parses input supplied by anonymous clients
over the internet. Both are places where a defect is a vulnerability rather than a bug, so
this policy is more specific than a template.

## Reporting a vulnerability

**Do not open a public issue.**

Report privately through
[GitHub Security Advisories](https://github.com/KyraLabs/easyrelay/security/advisories/new).
This creates a private thread with the maintainers, supports a draft fix, and can issue a CVE
if one is warranted.

Please include:

- The version or commit affected.
- What an attacker gains, concretely.
- A reproduction: the exact events, filters or messages involved, ideally as a test case.
- Any configuration required for the issue to apply.

You do not need a working exploit. A precise description of the flaw is enough.

### What to expect

| Stage | Target |
| --- | --- |
| Acknowledgement | 72 hours |
| Initial assessment, with a severity judgement | 7 days |
| Fix or a stated plan with dates | 30 days for high and critical |
| Public disclosure | Once a fix ships, or 90 days, whichever comes first |

If a deadline is going to be missed, you will be told before it passes rather than after.
Credit is given in the advisory unless you ask otherwise.

## What counts as a vulnerability

The relay's security boundary is the WebSocket connection: everything a client sends is
untrusted. In scope:

- **Signature or identity flaws.** Accepting an event whose signature does not verify,
  whose id does not match its canonical serialization, or that is attributed to a pubkey
  that did not sign it. Any bypass of NIP-42 authentication or NIP-70 protection.
- **Memory safety.** Any crash, out-of-bounds access, use-after-free or integer overflow
  reachable from client input, including the NIP-77 frame decoder, which parses length
  fields supplied by a peer.
- **Resource exhaustion with amplification.** Input where a small message causes
  disproportionate memory, CPU or disk use — an unbounded allocation driven by a
  client-supplied length, a filter that makes the relay scan without limit, a subscription
  that buffers without bound.
- **Policy bypass.** Circumventing rate limits, admission policy, allow and deny lists, or
  event size and tag limits.
- **Data integrity.** Causing another author's events to be deleted or replaced, including
  through NIP-09 deletion requests or replaceable-event tie-break handling.
- **Information disclosure.** Leaking events that authentication should have gated, or
  private material into logs or metrics.

## What does not count

- **Volumetric denial of service** from a client that simply sends a lot of valid traffic.
  Rate limiting bounds it; that is capacity planning, not a vulnerability. Amplification is
  a vulnerability, and the distinction is whether the cost to the relay is disproportionate
  to the cost to the attacker.
- **Problems that require a configuration the documentation warns against**, such as
  disabling rate limits or exposing the metrics endpoint publicly.
- **Vulnerabilities in dependencies with no path through easyrelay.** Report those upstream.
  If there is a path through easyrelay, it is in scope here — tell us about it.
- **Missing hardening that is not yet built.** The relay is pre-alpha; see the
  [roadmap](docs/roadmap.md). Unimplemented is not the same as vulnerable. If something on
  the roadmap is more urgent than its phase suggests, say so and it will be reprioritised.

## Supported versions

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Tagged releases | None yet |

easyrelay is pre-alpha and there is no released version. Once releases exist, this table
will state which ones receive fixes.

## For operators

Until the hardening in Phase 3 of the [roadmap](docs/roadmap.md) is complete, easyrelay is
not ready to be exposed to the public internet. When it is, the relevant guidance lives in
[docs/operations.md](docs/operations.md): run behind a reverse proxy, keep the metrics
endpoint off the public interface, run as an unprivileged user, and keep the data directory
backed up.

## Safe harbour

Research conducted in good faith under this policy is welcome, and the project will not
pursue or support action against you for it. Please test against your own relay rather than
someone else's, do not access data that is not yours, and do not degrade a service other
people are using.
