#!/bin/bash
set -euo pipefail

# MinimalWM - developer mode
# Rebuilds and restarts the app automatically when source files change.
#
# Usage:
#   ./dev.sh            # run with auto-rebuild on file changes
#   ./dev.sh --once     # build once, run once
#   ./dev.sh --no-watch # run current build without watching

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Sources"
STABLE_BIN="$HOME/bin/minimalWM"
APP_PID=""

# macOS tracks Accessibility trust by binary path + code hash. A freshly
# compiled binary has a new hash each time, which silently revokes the
# permission. We copy to a stable path AND codesign with a self-signed
# identity ("MinimalWM Developer") whose designated requirement is based on
# the certificate leaf, not the cdhash — so trust survives every rebuild.
CODESIGN_IDENTITY="MinimalWM Developer"

build() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building minimalWM..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    swift build 2>&1
    mkdir -p "$HOME/bin"
    cp "$(swift build --show-bin-path 2>/dev/null)/minimalWM" "$STABLE_BIN"
    chmod +x "$STABLE_BIN"
    codesign --force --sign "$CODESIGN_IDENTITY" "$STABLE_BIN" 2>&1 \
        || echo "  ⚠ codesign failed — Accessibility permission will reset on rebuild"
    echo "  Build done -> $STABLE_BIN"
}

stop_app() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        echo "  Stopping app (pid $APP_PID)"
        kill "$APP_PID"
        wait "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
}

run_app() {
    stop_app
    echo "  Launching minimalWM..."
    "$STABLE_BIN" &
    APP_PID=$!
    echo "  Running (pid $APP_PID)"
}

watch_loop() {
    echo "  Watching $SRC_DIR for changes..."
    echo "  Press Ctrl+C to stop."

    local last_hash=""
    local first=true

    while true; do
        local hash="$(find "$SRC_DIR" -type f -name '*.swift' -exec md5 -q {} + 2>/dev/null | md5)"

        if [ "$hash" != "$last_hash" ]; then
            last_hash="$hash"
            if [ "$first" = false ]; then
                build
                run_app
            else
                first=false
            fi
        fi

        sleep 1
    done
}

trap "echo ''; echo 'Stopping...'; stop_app; exit 0" SIGINT SIGTERM

if [ "$#" -ge 1 ]; then
    case "$1" in
        --once)
            build
            run_app
            echo "  Ctrl+C to stop."
            wait "$APP_PID"
            ;;
        --no-watch)
            run_app
            echo "  Ctrl+C to stop."
            wait "$APP_PID"
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
else
    build
    run_app
    watch_loop
fi