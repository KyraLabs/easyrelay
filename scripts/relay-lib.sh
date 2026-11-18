# Shared by the scripts that drive a real relay binary with nak. Source it; do not run it.
#
# Expects `port` and `workdir` to be set by the caller. Provides fail, start_relay,
# stop_relay and publish.

relay_binary=$(realpath "${RELAY_BINARY:-zig-out/bin/easyrelay}")
relay_pid=
log="$workdir/relay.log"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v nak >/dev/null || fail "nak is not on PATH. See https://github.com/fiatjaf/nak"
[ -x "$relay_binary" ] || fail "$relay_binary is missing. Run 'zig build' first."

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exec 3<&- 3>&-
}

port_open && fail "something is already listening on port $port"

start_relay() {
    (cd "$workdir" && EASYRELAY_NETWORK_PORT=$port exec "$relay_binary") >>"$log" 2>&1 &
    relay_pid=$!
    for _ in $(seq 1 50); do
        port_open && return 0
        sleep 0.1
    done
    fail "the relay did not start:
$(cat "$log")"
}

# SIGTERM, then wait for the process itself rather than for the port.
stop_relay() {
    kill -TERM "$relay_pid"
    wait "$relay_pid" || fail "the relay exited with status $? on SIGTERM:
$(tail -5 "$log")"
    relay_pid=
}

# Prints the id of the event if the relay answered OK true, and nothing otherwise.
publish() {
    local output
    output=$(nak event -c "$1" "ws://127.0.0.1:$port" </dev/null 2>&1) || return 0
    echo "$output" | grep -q "success" || return 0
    echo "$output" | grep -o '"id":"[a-f0-9]\{64\}"' | head -1 | cut -d'"' -f4
}

# Counts how many of the ids in file $1 the relay returns.
count_present() {
    local found=0 batch=()
    while read -r id; do
        batch+=(-i "$id")
        if [ "${#batch[@]}" -ge 100 ]; then
            found=$((found + $(nak req "${batch[@]}" "ws://127.0.0.1:$port" </dev/null 2>/dev/null | grep -c '"id"')))
            batch=()
        fi
    done <"$1"
    if [ "${#batch[@]}" -gt 0 ]; then
        found=$((found + $(nak req "${batch[@]}" "ws://127.0.0.1:$port" </dev/null 2>/dev/null | grep -c '"id"')))
    fi
    echo "$found"
}
