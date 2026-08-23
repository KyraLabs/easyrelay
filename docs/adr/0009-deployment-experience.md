# 0009. Zero-configuration defaults, TLS via a bundled proxy

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

"Trivial to run" is one of the project's three goals ([overview.md](../overview.md#goals)), not
a nice-to-have. Goals that are not attached to deliverables do not survive contact with a
roadmap, so this record fixes what the phrase actually commits the project to.

Standing up a Nostr relay today involves, in rough order of how often people get stuck:
obtaining a TLS certificate and configuring a reverse proxy; installing and configuring a
database; writing a configuration file before anything will start; and discovering after the
fact that a default was wrong for a public deployment.

The first is by far the largest obstacle. Nostr clients require `wss://`, so a relay is not
usable from the public internet without TLS, and configuring a proxy is the step that most
often stops someone who is otherwise perfectly capable of running a server. Meanwhile
[ADR-0004](0004-websocket-transport.md) and [operations.md](../operations.md) delegate TLS to a
reverse proxy, which is operationally correct and also precisely the step being complained
about.

The second and third are already solved by decisions taken elsewhere: LMDB is embedded
([ADR-0003](0003-storage-engine-lmdb.md)) and `libsecp256k1` is vendored
([ADR-0006](0006-cryptography.md)), so there is nothing to install and nothing to provision.

## Decision

Four commitments, each testable:

1. **The relay starts with no configuration.** `easyrelay` with no arguments and no file binds
   `127.0.0.1:7777`, creates its data directory under the working directory, and serves. Every
   setting in [configuration.md](../configuration.md) has a default that is correct for a real
   deployment.
2. **The relay does not terminate TLS, and the project ships the thing that does.**
   `deploy/docker-compose.yml` in this repository runs easyrelay behind Caddy, parameterised by
   a single `RELAY_DOMAIN` environment variable. This is the documented default path to a public
   relay, and it is one command.
3. **`easyrelay init` emits a fully commented configuration file** with every default filled in,
   so tuning starts from a complete document rather than from the reference manual.
4. **Configuration errors are actionable.** Full validation at startup; an unknown key, an
   out-of-range value or a contradictory combination stops the relay with a message naming the
   key and stating the fix. No silently ignored lines, no stack traces.

Built-in ACME is **not** adopted. See below.

## Consequences

The default path to a working relay is one command, and the default path to a public relay is
one command plus a domain name. That is the bar this record exists to hold the project to, and
the roadmap's Phase 2 and Phase 3 exit criteria test it by having someone unfamiliar with the
project follow the README and be timed.

Defaults become a correctness surface rather than a convenience. A default that is wrong for a
public relay is now a bug, which is why the relay binds loopback, keeps `storage.durable` on and
enables rate limits out of the box — see the tension noted in
[overview.md](../overview.md#the-tension-worth-naming). The friction of loopback-by-default is
absorbed by the compose file and by a startup message that says how to change it, rather than by
an unsafe default.

Shipping `deploy/docker-compose.yml` means the project maintains a Caddy configuration and a
container image as release artifacts, and tests them. That is real ongoing work, and it is the
price of the goal.

Anyone who wants a different topology — an existing nginx, a relay behind an ingress controller,
TLS terminated at a load balancer — is unaffected. The relay speaks plaintext WebSocket and does
not care what is in front of it.

## Alternatives considered

**Built-in ACME in the relay.** One binary, one command, a real certificate, nothing else
running. Genuinely the easiest possible experience, and the strongest argument against the
decision taken here. Rejected for now on three grounds: it puts certificate issuance, renewal
and a TLS stack inside a process whose security-critical surface is currently limited to
signature verification; it requires binding port 443, which pulls in privilege handling that the
relay otherwise does not need; and it duplicates, less well, what Caddy already does in the
bundled compose file. The gap in ease between "one command" and "one command plus a container
runtime" is small; the gap in maintenance burden is not.

**No bundled deployment artifacts; document the proxy setup and stop there.** This is the
conventional choice and it is what most relays do. Rejected because it is exactly the friction
the third goal exists to remove. Documentation that explains how to configure Caddy is not the
same thing as not having to.

**Interactive first-run setup wizard.** Prompt for domain, contact and relay name on first
start. Rejected: it does not compose with containers, systemd or configuration management, and
`easyrelay init` produces the same result without owning a terminal.

**Ship defaults tuned for a demo** — bind `0.0.0.0`, durability off, no rate limits — so the
first run is maximally frictionless. Rejected firmly. A default that makes the first five
minutes pleasant and the first month dangerous is not ease, it is a trap.

## Revisit when

The compose path measurably fails the Phase 3 exit criterion — an unfamiliar operator cannot get
a public relay running in the target time — or a well-maintained Zig ACME library exists that
would make built-in TLS a small, containable addition rather than a new security surface.
