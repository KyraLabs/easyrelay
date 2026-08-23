# NIP coverage

This table is the source of truth for the `supported_nips` array in the NIP-11 relay
information document. A NIP is listed as `supported` only once its conformance tests pass; the
NIP-11 document must never advertise more than this table does.

Status values: `supported`, `in progress`, `planned`, `out of scope`.

## Target set

| NIP | Name | Status | Phase | Notes |
| --- | --- | --- | --- | --- |
| [01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Basic protocol flow | planned | 1–2 | Events, filters, subscriptions, kind semantics. The whole of [protocol.md](protocol.md). |
| [09](https://github.com/nostr-protocol/nips/blob/master/09.md) | Event deletion | planned | 3 | Author-scoped only; tombstones prevent reinstatement. |
| [11](https://github.com/nostr-protocol/nips/blob/master/11.md) | Relay information document | planned | 2 | Served on `Accept: application/nostr+json`. Generated from configuration and from this table. |
| [13](https://github.com/nostr-protocol/nips/blob/master/13.md) | Proof of work | planned | 4 | Configurable minimum difficulty; validates the committed `nonce` tag, not just leading zeroes. |
| [40](https://github.com/nostr-protocol/nips/blob/master/40.md) | Expiration timestamp | planned | 3 | Reaper plus query-time filtering. |
| [42](https://github.com/nostr-protocol/nips/blob/master/42.md) | Authentication of clients | planned | 3 | Kind 22242 challenge/response; gates writes, reads, or both. |
| [45](https://github.com/nostr-protocol/nips/blob/master/45.md) | Event counts | planned | 4 | Exact counts from index cursors, subject to the same scan budget as queries. |
| [50](https://github.com/nostr-protocol/nips/blob/master/50.md) | Search capability | planned | 4 | Needs its own full-text index; the largest single item in Phase 4. |
| [65](https://github.com/nostr-protocol/nips/blob/master/65.md) | Relay list metadata | planned | 2 | For a relay this is correct replaceable handling of kind 10002. No special-casing. |
| [70](https://github.com/nostr-protocol/nips/blob/master/70.md) | Protected events | planned | 3 | The `-` tag; requires NIP-42, so it ships alongside it. |
| [77](https://github.com/nostr-protocol/nips/blob/master/77.md) | Negentropy syncing | planned | 5 | Set reconciliation, both initiator and responder. No Zig implementation exists; ported from the C++ reference. |
| [86](https://github.com/nostr-protocol/nips/blob/master/86.md) | Relay management API | planned | 4 | Authenticated JSON-RPC over HTTP for operator actions. |

## Explicitly out of scope

| NIP | Reason |
| --- | --- |
| 16, 33 | Merged into NIP-01. Their behaviour is covered by kind semantics; they are not separate features. |
| 04, 44, 59 | Encryption schemes. A relay stores and serves these events as opaque regular events; there is nothing for it to implement. |
| 46 | Remote signing is a client and signer concern. Provided by `zig-nostr/nostr` for other consumers, unused here. |
| 47, 57 | Wallet and zap flows. easyrelay carries the events; it does not participate. |

## Adding a NIP

1. Add the row here with status `in progress` and the phase that will deliver it.
2. Write the conformance tests in `tests/conformance/` from the NIP text before implementing.
3. Implement under `src/nips/`.
4. Flip the status to `supported` in the same commit that makes the tests pass.

Step 4 is what keeps the NIP-11 document honest: `supported_nips` is generated from this table,
so a NIP cannot be advertised without its tests passing.
