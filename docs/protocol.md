# Protocol reference

This is the behavioural contract easyrelay implements. Every rule here is backed by a test in
`tests/conformance/`. Where this document and the
[NIPs](https://github.com/nostr-protocol/nips) disagree, the NIPs win and this document is a
bug.

## Event structure

```json
{
  "id":         "<32-byte lowercase hex of the SHA-256 of the canonical serialization>",
  "pubkey":     "<32-byte lowercase hex of the author's x-only public key>",
  "created_at": 1700000000,
  "kind":       1,
  "tags":       [["e", "<hex>", "<relay url>"], ["p", "<hex>"]],
  "content":    "<arbitrary string>",
  "sig":        "<64-byte lowercase hex BIP-340 Schnorr signature over id>"
}
```

### Canonical serialization

The id is the SHA-256 of the UTF-8 bytes of:

```
[0,<pubkey>,<created_at>,<kind>,<tags>,<content>]
```

serialized as JSON with **no whitespace** anywhere, and with string escaping restricted to
exactly these sequences:

| Character | Escape |
| --- | --- |
| line break (0x0A) | `\n` |
| double quote (0x22) | `\"` |
| backslash (0x5C) | `\\` |
| carriage return (0x0D) | `\r` |
| tab (0x09) | `\t` |
| backspace (0x08) | `\b` |
| form feed (0x0C) | `\f` |

Every other character is emitted verbatim. In particular: no `\uXXXX` escapes, no escaping of
forward slashes, no escaping of non-ASCII. A general-purpose JSON encoder does not guarantee
this, so a dedicated serializer is used. `zig-nostr/nostr` provides one; easyrelay verifies it
against the vectors in `tests/vectors/` rather than trusting it.

An event whose recomputed id does not match the submitted `id` is rejected with `invalid:`.

### Signature

`sig` is a BIP-340 Schnorr signature over the 32 raw bytes of `id`, verified against the x-only
public key in `pubkey`. Verification uses `libsecp256k1`; see
[ADR-0006](adr/0006-cryptography.md). Failure is rejected with `invalid:`.

## Messages

### Client to relay

| Message | Form | Notes |
| --- | --- | --- |
| `EVENT` | `["EVENT", <event>]` | Publish |
| `REQ` | `["REQ", <sub_id>, <filter>...]` | Open or replace a subscription |
| `CLOSE` | `["CLOSE", <sub_id>]` | Close a subscription |
| `AUTH` | `["AUTH", <event>]` | NIP-42 response to a challenge |
| `COUNT` | `["COUNT", <sub_id>, <filter>...]` | NIP-45 |
| `NEG-OPEN` | `["NEG-OPEN", <sub_id>, <filter>, <hex msg>]` | NIP-77 |
| `NEG-MSG` | `["NEG-MSG", <sub_id>, <hex msg>]` | NIP-77 |
| `NEG-CLOSE` | `["NEG-CLOSE", <sub_id>]` | NIP-77 |

`sub_id` is a non-empty string, at most 64 characters, scoped to the connection. A `REQ` reusing
an open `sub_id` replaces that subscription. A `REQ` carrying no filters at all is a valid
subscription that matches nothing: it is answered with `EOSE` and stays open, because zero
filters OR-ed together is what it asks for.

### Relay to client

| Message | Form | Notes |
| --- | --- | --- |
| `EVENT` | `["EVENT", <sub_id>, <event>]` | A stored or live event |
| `OK` | `["OK", <event_id>, <bool>, <message>]` | Result of an `EVENT` |
| `EOSE` | `["EOSE", <sub_id>]` | End of stored events |
| `CLOSED` | `["CLOSED", <sub_id>, <message>]` | Subscription terminated by the relay |
| `NOTICE` | `["NOTICE", <message>]` | Human-readable message |
| `AUTH` | `["AUTH", <challenge>]` | NIP-42 challenge |
| `COUNT` | `["COUNT", <sub_id>, {"count": <n>}]` | NIP-45 |
| `NEG-MSG` / `NEG-ERR` | see NIP-77 | NIP-77 |

Every `EVENT` sent in response to a `REQ` precedes that subscription's `EOSE`. After `EOSE`, the
subscription only carries events that arrive subsequently.

## Machine-readable result prefixes

`OK` messages with `false`, and all `CLOSED` messages, begin with one of these prefixes followed
by a colon, a space, and a human-readable reason:

| Prefix | Meaning |
| --- | --- |
| `duplicate:` | The event is already stored |
| `pow:` | Proof-of-work below the relay's minimum (NIP-13) |
| `blocked:` | The author or the event is on a deny list |
| `rate-limited:` | The client is sending too fast, or the write queue is full |
| `invalid:` | The event is malformed, the id is wrong, or the signature does not verify |
| `restricted:` | Writing requires a privilege this client does not have |
| `auth-required:` | The client must complete NIP-42 authentication first |
| `error:` | An internal failure |

`duplicate:` is returned with `OK` `true`, not `false`: the client's event is present on the
relay, which is what it asked for.

## Filters

```json
{
  "ids":     ["<64-char lowercase hex>", ...],
  "authors": ["<64-char lowercase hex>", ...],
  "kinds":   [1, 7],
  "#e":      ["<64-char lowercase hex>", ...],
  "#p":      ["<64-char lowercase hex>", ...],
  "#<a-zA-Z>": ["<arbitrary tag value>", ...],
  "since":   1700000000,
  "until":   1700003600,
  "limit":   500
}
```

Matching rules:

- Within one field, values are **OR**-ed. Across fields, conditions are **AND**-ed.
- An absent field imposes no constraint. An empty array matches nothing.
- `since` and `until` are inclusive: `since <= created_at <= until`.
- Tag filters use a single-letter key (`a`-`z`, `A`-`Z`) and match the tag's **first value**. A
  `#` key that is not exactly one letter is a malformed filter. Ignoring it would widen the
  result set, and answering a narrower question with more events is worse than refusing it.
- `ids`, `authors`, `#e` and `#p` must be exactly 64 lowercase hex characters. Anything else is
  a malformed filter, not a filter that matches nothing.
- Numeric fields must be integers within range: a `kind` outside 0–65535, or a negative `limit`,
  is a malformed filter rather than a clamped one. Truncating 65537 into kind 1 would subscribe
  the client to something it did not ask for.
- A field NIP-01 does not define is ignored, so that a client sending a field for a NIP this
  relay does not implement still gets an answer.
- Multiple filters in one `REQ` are OR-ed against each other; an event matching any of them is
  sent once.
- `limit` applies **only to the stored-event phase** and selects the *most recent* matching
  events. It does not cap the live stream that follows `EOSE`.
- Events are streamed newest-first by `created_at`, tie-broken by ascending id.

The relay caps `limit` at its configured `max_limit` and applies `default_limit` when the field
is absent. Both are advertised in the NIP-11 document. When several filters in one `REQ` name
different limits, the largest applies across the merged result, so that no filter is served
fewer events than it asked for.

## Kind semantics

Kind ranges determine storage behaviour. As of the current NIP-01 revision:

| Range | Class | Storage behaviour |
| --- | --- | --- |
| `n == 1`, `n == 2`, `4 <= n < 45`, `1000 <= n < 10000` | Regular | Every event is stored |
| `n == 0`, `n == 3`, `10000 <= n < 20000` | Replaceable | Only the latest per `(pubkey, kind)` |
| `20000 <= n < 30000` | Ephemeral | Never stored; validated, fanned out, discarded |
| `30000 <= n < 40000` | Addressable | Only the latest per `(pubkey, kind, d)` |

Kinds outside every range are treated as regular.

**Replacement tie-break.** When two candidates share the same coordinate, the one with the
larger `created_at` wins. If `created_at` is also equal, the one with the **lexically smaller
id** wins. An incoming event that loses the tie-break is not stored and is answered with
`duplicate:`.

**Addressable coordinates.** The `d` tag's first value identifies the event. A missing `d` tag,
or a `d` tag with no value, is treated as the empty string — so `["d"]`, `["d", ""]` and an
absent `d` all address the same slot.

Superseded events are removed from the store, not merely hidden.

## Structural limits

Enforced before signature verification and advertised in NIP-11 `limitation`:

| Limit | Default | Rejection |
| --- | --- | --- |
| Serialized event size | 65536 bytes | `invalid:` |
| Message size | 131072 bytes | connection closed |
| Tag count per event | 2000 | `invalid:` |
| Content length | 65536 bytes | `invalid:` |
| Subscriptions per connection | 20 | `CLOSED` with `blocked:` |
| Filters per `REQ` | 10 | `CLOSED` with `invalid:` |
| `created_at` upper bound | now + 900 s | `invalid:` |
| `created_at` lower bound | unset | `invalid:` |

All are configurable; see [configuration.md](configuration.md).

## References

- [NIP-01 — Basic protocol flow](https://github.com/nostr-protocol/nips/blob/master/01.md)
- [BIP-340 — Schnorr signatures](https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki)
- [Full NIP index](https://github.com/nostr-protocol/nips)
