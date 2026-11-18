# Operations

> Describes the operational surface Phase 3 delivers; see the [roadmap](roadmap.md).

## Deployment model

One binary, one data directory, and a reverse proxy that terminates TLS. A configuration file is
optional — every setting has a working default. easyrelay binds to loopback and does not speak
TLS itself: certificates, renewal and HTTP/2 are the proxy's job, and it does that job better.

```
client ──TLS──> Caddy / nginx ──plaintext ws──> easyrelay ──> LMDB data directory
```

Delegating TLS does not mean delegating the work to you. The project ships the proxy
configuration, and that is the documented default path. See
[ADR-0009](adr/0009-deployment-experience.md).

## The default path: bundled compose

Point a domain's A record at the machine, then:

```bash
curl -LO https://github.com/KyraLabs/easyrelay/raw/main/deploy/docker-compose.yml
RELAY_DOMAIN=relay.example.com docker compose up -d
```

That is a public relay on `wss://relay.example.com`. Caddy obtains the certificate and renews
it; easyrelay runs on the internal network from the `ghcr.io/kyralabs/easyrelay` image, with its
data on a named volume, a read-only root filesystem and every capability dropped; `/metrics`
answers 404 through Caddy. `EASYRELAY_VERSION` pins an image tag; it defaults to `latest`.

To change relay settings, drop an `easyrelay.zon` next to the compose file — the directory is
mounted read-only as the relay's working directory, so the file is read when it exists.
Generate a starting point with `docker compose run --rm easyrelay init > easyrelay.zon`, then
`docker compose up -d` again. If `metrics.path` is changed, change the Caddy block in the compose
file to match, or the new path is public.

`docker compose stop` sends SIGTERM and allows 60 seconds for the write queue to drain.

Everything below is for operators who want to run the binary directly instead.

## Running the binary directly

```bash
easyrelay                                    # loopback, defaults, data in ./data
easyrelay --config /etc/easyrelay/easyrelay.zon
easyrelay init > easyrelay.zon               # commented file with every default filled in
easyrelay doctor --config ./easyrelay.zon    # validate config and environment before starting
```

`easyrelay doctor` checks that the configuration parses and is internally consistent, that the
data directory exists and is writable, how much map-size headroom remains, and whether the relay
will be reachable from anywhere other than loopback. Run it after any configuration change and
before restarting a relay people depend on. It reads the store without taking its lock, so it
also runs beside a serving relay:

```
ok   configuration  /etc/easyrelay/easyrelay.zon
ok   data directory /var/lib/easyrelay is writable
ok   store          1204331 events, 41.7% of storage.map_size used
ok   network        127.0.0.1:7777 is reachable from this machine only; a TLS reverse proxy in front makes it public
warn port           7777 is in use; if that is not this relay already running, choose another network.port
```

A `fail` line exits with status 1; `warn` lines do not. The store fails past 95% of
`storage.map_size` and warns past 80%.

## systemd unit

The unit ships as [`deploy/easyrelay.service`](../deploy/easyrelay.service), and is attached to
every release. It runs the relay as an `easyrelay` system user with `/etc/easyrelay` as its
working directory, so `/etc/easyrelay/easyrelay.zon` is read when it exists, and keeps the data in
`/var/lib/easyrelay`:

```bash
install -m 0755 easyrelay /usr/local/bin/easyrelay
install -m 0644 easyrelay.service /etc/systemd/system/easyrelay.service
useradd --system --home-dir /var/lib/easyrelay --shell /usr/sbin/nologin easyrelay
systemctl daemon-reload && systemctl enable --now easyrelay
```

`LimitNOFILE` matters: every connection is a file descriptor, and the default limit will cap
concurrency long before anything else does. `TimeoutStopSec=60s` is the time SIGTERM has to
drain the write queue.

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
# online backup, while the relay keeps serving
easyrelay backup --config /etc/easyrelay/easyrelay.zon --out /backup/easyrelay-$(date -Iseconds).mdb
```

The backup is a single compacted file holding every event committed when it began. `--out` must
not exist. The command reads the store without taking the relay's lock, so it runs beside it.

To restore, with `storage.path` at `/var/lib/easyrelay`:

```bash
systemctl stop easyrelay
cp /backup/easyrelay-<date>.mdb /var/lib/easyrelay/events/data.mdb
chown easyrelay:easyrelay /var/lib/easyrelay/events/data.mdb
systemctl start easyrelay
```

Test the restore path before needing it. A backup that has never been restored is a hypothesis.
`scripts/backup-restore.sh` runs this sequence against a relay accepting writes, and CI runs it.

## Compaction

Compaction rewrites the store without its free pages, reclaiming disk after large deletions. It
requires roughly as much free space as the current store, and produces a new file that replaces
the old one.

```bash
systemctl stop easyrelay
easyrelay compact --config /etc/easyrelay/easyrelay.zon
systemctl start easyrelay
```

`compact` refuses to run while a relay holds the store, and prints the file size before and
after.

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

`GET /health` returns 200 `ok` when the relay is accepting connections and its store answers
with under 95% of `storage.map_size` in use, and 503 otherwise.

## Logs

Structured JSON by default, one object per line, on stderr for the journal to collect:

```json
{"time":"2026-11-17T10:00:00Z","level":"info","scope":"server","message":"conn=42 closed: not reading what it subscribed to (network.write_buffer_limit)"}
```

Every line about a connection carries `conn=<n>`, a number assigned when it was accepted, so one
connection's lines can be followed with `grep 'conn=42 '`. Set `logging.format = .text` for a
readable terminal during development, and `logging.level = .debug` to see each connection open
and close. The startup summary goes to stdout.

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
