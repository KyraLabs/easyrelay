#!/usr/bin/env bash
#
# The pinned Zig version lives in three files that must agree:
#
#   .zigversion          read by editors, ZLS and CI
#   mise.toml            what `mise install` gives a contributor
#   build.zig.zon        minimum_zig_version, enforced by the compiler
#
# Drift between them is the classic "works on my machine" bug, and it surfaces as an
# unrelated CI failure days later. This script is the guard. CI runs it; run it yourself
# after changing the pin. See docs/adr/0001-language-and-toolchain.md.

set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    echo "error: $*" >&2
    exit 1
}

extract_quoted() {
    # First double-quoted value on the first line matching the given pattern.
    grep -E "$1" "$2" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

pinned=$(tr -d '[:space:]' < .zigversion)
[ -n "$pinned" ] || fail ".zigversion is empty"

mise_pinned=$(extract_quoted '^[[:space:]]*zig[[:space:]]*=' mise.toml)
zon_pinned=$(extract_quoted '^[[:space:]]*\.minimum_zig_version' build.zig.zon)

status=0
if [ "$mise_pinned" != "$pinned" ]; then
    echo "error: mise.toml pins '$mise_pinned' but .zigversion says '$pinned'" >&2
    status=1
fi
if [ "$zon_pinned" != "$pinned" ]; then
    echo "error: build.zig.zon minimum_zig_version is '$zon_pinned' but .zigversion says '$pinned'" >&2
    status=1
fi
[ "$status" -eq 0 ] || fail "the Zig version pin is inconsistent; make all three files agree"

if command -v zig >/dev/null 2>&1; then
    installed=$(zig version)
    if [ "$installed" != "$pinned" ]; then
        fail "zig $installed is on PATH but this project pins $pinned. Run 'mise install'.
The version is a pin, not a minimum: docs/adr/0001-language-and-toolchain.md."
    fi
    echo "ok: zig $pinned pinned consistently and installed"
else
    echo "ok: zig $pinned pinned consistently (compiler not on PATH, not checked)"
fi
