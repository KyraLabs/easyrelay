#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

relay_binary=${RELAY_BINARY:-zig-out/bin/easyrelay}
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

"$relay_binary" >/tmp/easyrelay-interop.log 2>&1 &
relay_pid=$!
trap 'kill "$relay_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
        exec 3<&- 3>&-
        break
    fi
    sleep 0.1
done
kill -0 "$relay_pid" 2>/dev/null || fail "the relay exited on startup:
$(cat /tmp/easyrelay-interop.log)"

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

echo "ok: nak published ${event_id:0:12} and read it back from ws://localhost:$port"
