#!/usr/bin/env bash
# Runs Trot from source with live reload: it builds a bare binary, runs it,
# and builds and restarts it when a Go file, an asset or mygo.json changes.
# A build that fails keeps the running one. Quit Trot, or press Ctrl-C, to
# stop.
#
# A bare binary rather than mygo dev's "Trot Dev" bundle: macOS 26 keeps the
# menu bar icon of that bundle hidden, even when System Settings allows it.
# TROT_DATA_DIR gives it settings of its own. Quit the everyday Trot first,
# or both take the hotkeys.
#
# Usage: scripts/dev.sh [launch arguments, such as -translate hello]
# TROT_DATA_DIR picks another data folder (default: Trot-dev beside Trot's).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TROT_DATA_DIR="${TROT_DATA_DIR:-$HOME/Library/Application Support/Trot-dev}"
OUT="$ROOT/.mygo/dev"
BIN="$OUT/trot"
STAMP="$OUT/built"

# MyGo creates its own data folder, but not one set with SetPath.
mkdir -p "$TROT_DATA_DIR" "$OUT"
cd "$ROOT"

APP=""
stop() {
    if [ -n "$APP" ] && kill -0 "$APP" 2>/dev/null; then
        kill "$APP" 2>/dev/null || true
        wait "$APP" 2>/dev/null || true
    fi
    APP=""
}
trap 'stop; exit 0' INT TERM

build() {
    touch "$STAMP.next"
    if go build -o "$BIN.next" ./cmd/trot; then
        mv "$BIN.next" "$BIN"
        mv "$STAMP.next" "$STAMP"
        return 0
    fi
    rm -f "$STAMP.next"
    return 1
}

# changed reports whether a source file is newer than the last build.
changed() {
    [ -n "$(find cmd internal resources mygo.json go.mod go.sum -newer "$STAMP" -type f \
        \( -name '*.go' -o -name '*.png' -o -name '*.json' -o -name 'go.mod' -o -name 'go.sum' \) \
        -not -name '*_test.go' -print -quit 2>/dev/null)" ]
}

start() {
    "$BIN" "$@" &
    APP=$!
    echo "==> Trot is running (pid $APP, data in $TROT_DATA_DIR)"
}

echo "==> building"
build
start "$@"
while true; do
    sleep 1
    if ! kill -0 "$APP" 2>/dev/null; then
        echo "==> Trot quit"
        exit 0
    fi
    if changed; then
        echo "==> rebuilding"
        if build; then
            stop
            start "$@"
        else
            echo "==> the build failed; Trot keeps running the last one"
        fi
    fi
done
