#!/usr/bin/env bash
#
# The Phase 1 interop criterion, run against the built binary rather than
# against easyrelay's own idea of the protocol:
#
#   nak event -c "hello" ws://localhost:7777
#   nak req -k 1 ws://localhost:7777
#
# Conformance tests check the relay against this project's reading of NIP-01.
# This checks it against a client somebody else wrote, which is the only way to
# find out that the reading was wrong. See docs/testing.md.
#
# The port is 7777 and is not configurable, because the criterion is about the
# relay that starts with no arguments and no file.

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

# The transport sets SO_REUSEPORT, so a relay already on this port would not
# stop this one from binding: the two would share the connections, and the
# event published to one would be read from the other. Refusing up front turns
# that into a message instead of a mystery.
if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
    exec 3<&- 3>&-
    fail "something is already listening on port $port"
fi

"$relay_binary" >/tmp/easyrelay-interop.log 2>&1 &
relay_pid=$!
trap 'kill "$relay_pid" 2>/dev/null || true' EXIT

# Waiting for the port rather than sleeping a guessed amount: a fixed sleep is
# either slower than it needs to be or shorter than it needs to be.
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
