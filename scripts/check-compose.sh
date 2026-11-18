#!/usr/bin/env bash
# Phase 3 exit criterion: deploy/docker-compose.yml with only RELAY_DOMAIN set yields a relay
# reachable over wss://. Run it against a stack already started with RELAY_DOMAIN=localhost,
# for which Caddy issues a certificate from its own local authority, hence --insecure.
set -euo pipefail

origin=${ORIGIN:-https://localhost}

fail() {
    echo "error: $*" >&2
    exit 1
}

for _ in $(seq 1 60); do
    [ "$(curl -sk --max-time 2 "$origin/health" || true)" = "ok" ] && break
    sleep 1
done
[ "$(curl -sk --max-time 2 "$origin/health")" = "ok" ] || fail "$origin/health never answered ok"

document=$(curl -sk --max-time 5 -H 'Accept: application/nostr+json' "$origin/")
echo "$document" | grep -q '"supported_nips"' || fail "no NIP-11 document at $origin/:
$document"

status=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$origin/metrics")
[ "$status" = "404" ] || fail "$origin/metrics answered $status; the proxy must not expose metrics"

upgrade=$(curl -sk --http1.1 --max-time 3 -i -N \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$origin/" || true)
echo "$upgrade" | head -1 | grep -q ' 101 ' || fail "the WebSocket upgrade through the proxy did not answer 101:
$(echo "$upgrade" | head -5)"
echo "$upgrade" | grep -qi 'sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=' ||
    fail "the upgrade answer does not carry the RFC 6455 accept key"

echo "ok: $origin serves health, NIP-11 and a WebSocket upgrade over TLS, and hides /metrics"
