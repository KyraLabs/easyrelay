# Configuration

> **Provisional.** The concrete file syntax is not settled — see
> [ADR-0007](adr/0007-configuration-format.md), which is decided in Phase 2. The **settings**
> below are stable; only their spelling may change. Examples use ZON, the current
> recommendation.

**A configuration file is optional.** Every setting has a default that is correct for a real
deployment, so `easyrelay` with no file and no arguments starts a working relay. Read this
document when you want to change something, not to get started — see the quick start in the
[README](../README.md).

easyrelay reads one configuration file, given by `--config <path>` or defaulting to
`./easyrelay.zon` if it exists. `easyrelay init` writes a fully commented file with every
default filled in, which is the easier way to start editing than transcribing from here.

Any setting may be overridden by an environment variable named `EASYRELAY_` followed by the
path in upper snake case: `limits.max_event_size` becomes `EASYRELAY_LIMITS_MAX_EVENT_SIZE`.
Environment variables win over the file, which is what containerised deployments need.

The configuration is validated fully at startup. An unknown key, an out-of-range value or a
contradictory combination is a startup failure with a message naming the key — never a silently
ignored line.

## Minimal example

```zig
.{
    .network = .{ .address = "127.0.0.1", .port = 7777 },
    .storage = .{ .path = "/var/lib/easyrelay" },
    .info = .{
        .name = "example relay",
        .description = "a relay",
        .contact = "mailto:admin@example.com",
    },
}
```

## `network`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `address` | string | `127.0.0.1` | Bind address. Default is loopback because easyrelay expects a reverse proxy in front of it. |
| `port` | u16 | `7777` | Bind port. |
| `max_connections` | usize | `1024` | Connections accepted before new ones are refused. |
| `handshake_timeout_ms` | u32 | `5000` | Time allowed to complete the WebSocket handshake. |
| `ping_interval_s` | u32 | `30` | Interval between pings on idle connections. `0` disables. |
| `idle_timeout_s` | u32 | `300` | Close a connection after this long with no traffic. `0` disables. |
| `write_buffer_limit` | usize | `1048576` | Per-connection pending write bytes before the connection is dropped. Backpressure, not buffering. |

## `storage`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `path` | string | `./data` | Data directory. |
| `map_size` | usize | `10737418240` | LMDB map size in bytes (10 GiB). Address space, not a disk reservation, but a hard ceiling. |
| `durable` | bool | `true` | Sync metadata on commit. Setting this to `false` trades durability for throughput and invalidates any benchmark comparison. |
| `max_scan` | usize | `100000` | Index entries a single query may examine before returning early. Bounds worst-case query cost. |
| `reaper_interval_s` | u32 | `60` | How often NIP-40 expiration and retention run. |

## `limits`

Defaults match [protocol.md](protocol.md#structural-limits) and are published in the NIP-11
`limitation` object.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_event_size` | usize | `65536` | Serialized event bytes. |
| `max_message_size` | usize | `131072` | WebSocket message bytes. |
| `max_event_tags` | usize | `2000` | Tags per event. |
| `max_content_length` | usize | `65536` | `content` bytes. |
| `max_subscriptions` | usize | `20` | Open subscriptions per connection. |
| `max_filters` | usize | `10` | Filters per `REQ`. |
| `max_limit` | usize | `5000` | Cap applied to a filter's `limit`. |
| `default_limit` | usize | `500` | Applied when `limit` is absent. |
| `max_subid_length` | usize | `64` | Subscription id characters. |
| `created_at_upper_limit_s` | i64 | `900` | Seconds into the future an event may claim. |
| `created_at_lower_limit_s` | ?i64 | `null` | Seconds into the past. `null` disables. |

## `rate_limit`

Token buckets. `null` on any bucket disables it.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `events_per_second` | ?f64 | `10` | Sustained accepted-event rate per connection. |
| `events_burst` | usize | `50` | Burst allowance. |
| `messages_per_second` | ?f64 | `50` | Sustained inbound message rate per connection, of any type. |
| `subscriptions_per_minute` | ?f64 | `60` | `REQ` rate per connection. |
| `write_queue_depth` | usize | `4096` | Pending writes before events are refused with `rate-limited:`. |

## `policy`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `allowed_pubkeys` | ?[]string | `null` | If set, only these authors may write. |
| `blocked_pubkeys` | []string | `[]` | These authors may never write. |
| `allowed_kinds` | ?[]u32 | `null` | If set, only these kinds are accepted. |
| `blocked_kinds` | []u32 | `[]` | These kinds are always rejected. |
| `min_pow_difficulty` | u8 | `0` | NIP-13 minimum leading zero bits. `0` disables. |
| `auth_required_for_write` | bool | `false` | Require NIP-42 before accepting events. |
| `auth_required_for_read` | bool | `false` | Require NIP-42 before serving subscriptions. |
| `plugin` | ?string | `null` | Path to an external write-policy executable (Phase 4). |

An allow list and a deny list containing the same entry is a configuration error, not a
precedence puzzle.

## `retention`

Off by default. See [storage.md](storage.md#retention).

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_age_s` | ?i64 | `null` | Delete events older than this. |
| `max_events` | ?usize | `null` | Delete oldest events beyond this count. |
| `per_kind` | map | `{}` | Per-kind `max_age_s` overrides. |

## `info`

Feeds the NIP-11 document directly. `supported_nips` is not configurable: it is generated from
[nips.md](nips.md), so the relay cannot advertise a NIP whose tests do not pass.

| Key | Type | Default |
| --- | --- | --- |
| `name` | ?string | `null` |
| `description` | ?string | `null` |
| `banner` | ?string | `null` |
| `icon` | ?string | `null` |
| `pubkey` | ?string | `null` |
| `contact` | ?string | `null` |
| `posting_policy` | ?string | `null` |
| `privacy_policy` | ?string | `null` |
| `terms_of_service` | ?string | `null` |
| `relay_countries` | []string | `[]` |
| `language_tags` | []string | `[]` |

## `logging`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `level` | enum | `info` | `error`, `warn`, `info`, `debug`. |
| `format` | enum | `json` | `json` or `text`. |

## `metrics`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Serve `GET /metrics`. |
| `path` | string | `/metrics` | Exposition path. |

Metrics are served on the same listener as the relay. Restrict access at the reverse proxy; see
[operations.md](operations.md).
