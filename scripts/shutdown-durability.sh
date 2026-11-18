#!/usr/bin/env bash
# Phase 3 exit criterion: SIGTERM during sustained writes loses no acknowledged event.
set -euo pipefail
cd "$(dirname "$0")/.."

port=${PORT:-7781}
publishers=${PUBLISHERS:-4}
workdir=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$workdir"' EXIT
# shellcheck source=scripts/relay-lib.sh
source scripts/relay-lib.sh

# Every publisher signs with nak's machine key, so the per-author budget would refuse most of
# them; this test is about shutdown, not about rate limits.
export EASYRELAY_RATE_LIMIT_AUTHOR_EVENTS_PER_SECOND=null

start_relay

for p in $(seq 1 "$publishers"); do
    (
        for i in $(seq 1 100000); do
            publish "durability $p-$i" >>"$workdir/acked-$p"
        done
    ) &
done

sleep "${WRITE_SECONDS:-3}"
stop_relay
kill $(jobs -p) 2>/dev/null || true
wait 2>/dev/null || true

cat "$workdir"/acked-* | sort -u >"$workdir/acked"
acked=$(wc -l <"$workdir/acked")
[ "$acked" -gt 0 ] || fail "no event was acknowledged before SIGTERM:
$(tail -5 "$log")"

start_relay
present=$(count_present "$workdir/acked")
stop_relay

[ "$present" -eq "$acked" ] || fail "$acked events were acknowledged before SIGTERM, but only $present are present after restart"
echo "ok: all $acked events acknowledged during sustained writes are present after SIGTERM and restart"
