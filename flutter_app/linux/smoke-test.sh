#!/usr/bin/env bash
set -euo pipefail
binary=$(realpath "${1:?Linux binary path required}")
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export IEUM_FLUTTER_DATA_DIR="$test_root/data"
export XDG_DATA_HOME="$test_root/xdg"
export IEUM_DISABLE_UPDATES=1
export IEUM_SMOKE_TEST=1
export IEUM_SMOKE_MARKER="$test_root/started"
export LIBGL_ALWAYS_SOFTWARE=1
timeout 35s xvfb-run -a dbus-run-session -- bash -c '
  printf "ieum-ci-keyring\n" | gnome-keyring-daemon --unlock --components=secrets > /dev/null
  "$1" > "$IEUM_FLUTTER_DATA_DIR.log" 2>&1 &
  app_pid=$!
  trap "kill $app_pid 2>/dev/null || true" EXIT
  for attempt in $(seq 1 100); do
    if ! kill -0 "$app_pid" 2>/dev/null; then cat "$IEUM_FLUTTER_DATA_DIR.log"; exit 1; fi
    if test -s "$IEUM_SMOKE_MARKER"; then cat "$IEUM_SMOKE_MARKER"; exit 0; fi
    sleep 0.2
  done
  cat "$IEUM_FLUTTER_DATA_DIR.log"
  exit 1
' bash "$binary"
