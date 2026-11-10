#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

relay_binary=$(realpath "${RELAY_BINARY:-zig-out/bin/easyrelay}")
port=7777
content="hello from the interop test"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v nak >/dev/null || fail "nak is not on PATH. See https://github.com/fiatjaf/nak"
[ -x "$relay_binary" ] || fail "$relay_binary is missing. Run 'zig build' first."

# SO_REUSEPORT would let a second relay share this port silently, so refuse if it is taken.
if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
    exec 3<&- 3>&-
    fail "something is already listening on port $port"
fi

# A fresh directory with no configuration file: what a first run sees.
workdir=$(mktemp -d)
log="$workdir/relay.log"
relay_pid=
trap 'kill "$relay_pid" 2>/dev/null || true; rm -rf "$workdir"' EXIT

start_relay() {
    (cd "$workdir" && exec "$relay_binary") >>"$log" 2>&1 &
    relay_pid=$!
    for _ in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
            exec 3<&- 3>&-
            break
        fi
        sleep 0.1
    done
    kill -0 "$relay_pid" 2>/dev/null || fail "the relay exited on startup:
$(cat "$log")"
}

stop_relay() {
    kill "$relay_pid"
    wait "$relay_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null || return 0
        sleep 0.1
    done
    fail "the relay did not release port $port"
}

start_relay

published=$(nak event -c "$content" "ws://localhost:$port" </dev/null 2>&1) ||
    fail "nak could not publish:
$published"
echo "$published" | grep -q "success" || fail "the relay refused the event:
$published"

event_id=$(echo "$published" | grep -o '"id":"[a-f0-9]\{64\}"' | head -1 | cut -d'"' -f4)
[ -n "$event_id" ] || fail "could not read the published event id from nak's output:
$published"

received=$(nak req -k 1 "ws://localhost:$port" </dev/null 2>&1) ||
    fail "nak could not subscribe:
$received"
echo "$received" | grep -q "$event_id" || fail "the relay did not return the event it accepted:
$received"
echo "$received" | grep -q "$content" || fail "the event came back with different content:
$received"

[ -d "$workdir/data/events" ] || fail "the relay did not create ./data/events in its working directory"

stop_relay
start_relay
after_restart=$(nak req -k 1 "ws://localhost:$port" </dev/null 2>&1) ||
    fail "nak could not subscribe after a restart:
$after_restart"
echo "$after_restart" | grep -q "$event_id" || fail "the event did not survive a restart:
$after_restart"

echo "ok: nak published ${event_id:0:12} and read it back from ws://localhost:$port, before and after a restart"
