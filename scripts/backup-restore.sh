#!/usr/bin/env bash
# Phase 3 exit criterion: the backup and restore runbook in docs/operations.md, executed end to
# end against a running relay that keeps accepting writes while the backup is taken.
set -euo pipefail
cd "$(dirname "$0")/.."

port=${PORT:-7782}
workdir=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$workdir"' EXIT
# shellcheck source=scripts/relay-lib.sh
source scripts/relay-lib.sh

export EASYRELAY_RATE_LIMIT_AUTHOR_EVENTS_PER_SECOND=null

start_relay
for i in $(seq 1 20); do publish "before the backup $i" >>"$workdir/before"; done
[ "$(wc -l <"$workdir/before")" -eq 20 ] || fail "the relay did not accept the first 20 events"

(for i in $(seq 1 100000); do publish "during the backup $i" >/dev/null; done) &
writer=$!
(cd "$workdir" && "$relay_binary" backup --out backup.mdb) ||
    fail "easyrelay backup failed against the running relay"
kill "$writer" 2>/dev/null || true
wait "$writer" 2>/dev/null || true

for i in $(seq 1 5); do publish "after the backup $i" >>"$workdir/after"; done
stop_relay

# The restore, as operations.md states it: stop, replace the data file, start.
cp "$workdir/backup.mdb" "$workdir/data/events/data.mdb"
start_relay
restored=$(count_present "$workdir/before")
lost=$(count_present "$workdir/after")
stop_relay

[ "$restored" -eq 20 ] || fail "only $restored of the 20 events written before the backup are in the restored store"
[ "$lost" -eq 0 ] || fail "$lost events written after the backup appeared in the restored store"
echo "ok: a backup taken during writes restored every event acknowledged before it, and none after"
