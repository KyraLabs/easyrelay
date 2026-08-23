# Operations

> Describes the target operational surface. Most of it lands in Phase 3; see the
> [roadmap](roadmap.md).

## Deployment model

One binary, one configuration file, one data directory, behind a reverse proxy that terminates
TLS. easyrelay binds to loopback by default and does not speak TLS itself — certificates,
renewal and HTTP/2 are the proxy's job, and it does that job better.

```
client ──TLS──> Caddy / nginx ──plaintext ws──> easyrelay ──> LMDB data directory
```

## systemd unit

```ini
[Unit]
Description=easyrelay
After=network.target

[Service]
Type=simple
User=easyrelay
Group=easyrelay
ExecStart=/usr/local/bin/easyrelay --config /etc/easyrelay/easyrelay.zon
Restart=on-failure
RestartSec=5s

StateDirectory=easyrelay
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/easyrelay
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

`LimitNOFILE` matters: every connection is a file descriptor, and the default limit will cap
concurrency long before anything else does.

## Reverse proxy

### Caddy

```
relay.example.com {
    @metrics path /metrics
    respond @metrics 404

    reverse_proxy 127.0.0.1:7777
}
```

Caddy handles the WebSocket upgrade and certificates without further configuration. The
`@metrics` block keeps the metrics endpoint off the public interface; scrape it directly on
loopback instead.

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;

    location /metrics { return 404; }

    location / {
        proxy_pass http://127.0.0.1:7777;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

The timeouts are the part people get wrong. Nostr subscriptions are long-lived and mostly idle;
nginx's 60-second default will disconnect healthy subscribers.

## Sizing the LMDB map

`storage.map_size` is a hard ceiling and cannot be raised without a restart. It reserves address
space, not disk, so a value well above expected growth costs nothing on a 64-bit host. Exceeding
it is a hard failure.

Start at ten times the expected steady-state size. Watch `easyrelay_store_map_used_ratio` and
raise it during a maintenance restart well before it approaches full.

Note that LMDB does not shrink after deletions: freed pages are reused, not returned. A store
that has been through a large expiration sweep will keep its file size.

## Backup

LMDB provides a consistent snapshot, so the data directory can be copied while the relay runs
and while writes continue. The copy is crash-consistent as of the moment it started.

```bash
# online backup
easyrelay backup --config /etc/easyrelay/easyrelay.zon --out /backup/easyrelay-$(date -Iseconds).mdb
```

To restore: stop the relay, replace the data directory contents with the backup, start it again.

Test the restore path before needing it. A backup that has never been restored is a hypothesis.

## Compaction

Compaction rewrites the store without its free pages, reclaiming disk after large deletions. It
requires roughly as much free space as the current store, and produces a new file that replaces
the old one.

```bash
systemctl stop easyrelay
easyrelay compact --config /etc/easyrelay/easyrelay.zon
systemctl start easyrelay
```

Only worth doing after a retention policy change or a large expiration sweep. Routine
compaction is unnecessary; LMDB reuses free pages on its own.

## Metrics

Prometheus exposition on `GET /metrics`. The metrics that matter:

| Metric | Type | Watch for |
| --- | --- | --- |
| `easyrelay_connections_active` | gauge | Approaching `network.max_connections` |
| `easyrelay_events_received_total` | counter | Labelled by outcome: accepted, duplicate, invalid, rate-limited, blocked |
| `easyrelay_event_validation_seconds` | histogram | Signature verification cost under load |
| `easyrelay_write_queue_depth` | gauge | Sustained non-zero means the writer is the bottleneck |
| `easyrelay_query_seconds` | histogram | p99 drift as the store grows |
| `easyrelay_query_scan_budget_exhausted_total` | counter | Queries truncated by `storage.max_scan` |
| `easyrelay_subscriptions_active` | gauge | Fan-out cost driver |
| `easyrelay_store_map_used_ratio` | gauge | Map size headroom |
| `easyrelay_store_events` | gauge | Store growth |

Alert on `write_queue_depth` sustained above zero and on `store_map_used_ratio` above 0.8. The
first means writes are backing up; the second means a hard failure is approaching.

`GET /health` returns 200 when the relay is accepting connections and its store is writable.

## Logs

Structured JSON by default, one object per line, to stdout for the journal to collect. Set
`logging.format = .text` for a readable terminal during development.

Logs never contain event content or full pubkeys at `info` level.

## Upgrades

1. Read the release notes for storage format changes.
2. Back up the data directory.
3. Stop, replace the binary, start.

`SIGTERM` triggers graceful shutdown: stop accepting, drain the write queue, commit, close.
Every event that received `OK true` is durable before the process exits. Allow enough time in
`TimeoutStopSec` for the queue to drain.

## Troubleshooting

**Clients disconnect after ~60 seconds.** The reverse proxy's read timeout. See the nginx
configuration above.

**`MDB_MAP_FULL` at startup or during writes.** `storage.map_size` is exhausted. Raise it and
restart; existing data is unaffected.

**File grows despite expiration running.** Freed pages are being reused, not returned, or a
long-lived reader is pinning old pages. Check `easyrelay_query_seconds` for very slow queries
and consider lowering `storage.max_scan`.

**High CPU with low throughput.** Signature verification on rejected events. Check the
`invalid` and `rate-limited` outcome labels on `easyrelay_events_received_total`, and tighten
`rate_limit` or `policy`.
