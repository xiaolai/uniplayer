#!/bin/bash
# Quick UI loop for the actual UniPlayer app.
#
# Builds only the app target into a warm, ignored derived-data directory, then
# relaunches the real app so the change can be judged immediately. It never runs
# tests: the normal gate still belongs to acceptance, not to every visual edit.
#
#   scripts/dev-ui.sh build   # incremental app build only
#   scripts/dev-ui.sh run     # build, quit any copy, relaunch the built app
#   scripts/dev-ui.sh shot    # capture the running app window to .build/ui-dev/last.png
#
# The built app keeps the real bundle identifier, so it uses the real
# preferences and library. Quit other copies first; two instances sharing one
# preferences store fight over window state.
set -euo pipefail
cd "$(dirname "$0")/.."

root=$PWD
derived=$root/.build/ui-dev
app=$derived/Build/Products/Debug/UniPlayer.app
tools=$root/.build/ui-dev-tools
mode=${1:-run}

find_developer() {
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo "$DEVELOPER_DIR"
    return
  fi
  local selected
  selected=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  case "$selected" in
    *Xcode*.app/Contents/Developer) echo "$selected"; return ;;
  esac
  local candidate
  for candidate in /Applications/Xcode.app/Contents/Developer "$HOME/Applications/Xcode.app/Contents/Developer"; do
    if [ -x "$candidate/usr/bin/xcodebuild" ]; then echo "$candidate"; return; fi
  done
  echo "dev-ui: no Xcode installation found; set DEVELOPER_DIR" >&2
  exit 1
}

developer=$(find_developer)

dev_pid() {
  pgrep -f "$app/Contents/MacOS/UniPlayer" 2>/dev/null | head -1 || true
}

installed_pid() {
  pgrep -f "/Applications/UniPlayer.app/Contents/MacOS/UniPlayer" 2>/dev/null | head -1 || true
}

quit_pid() {
  local pid=$1
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  local deadline=$((SECONDS + 10))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  kill -0 "$pid" 2>/dev/null && { echo "dev-ui: could not quit $pid" >&2; exit 1; }
  return 0
}

build() {
  local started=$SECONDS
  echo "dev-ui: building the app target"
  DEVELOPER_DIR=$developer xcodebuild \
    -project uniplayer.xcodeproj \
    -scheme uniplayer \
    -configuration Debug \
    -derivedDataPath "$derived" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    -quiet \
    build
  echo "dev-ui: build $((SECONDS - started))s"
}

window_id() {
  local deadline=$((SECONDS + 10))
  if [ ! -x "$tools/dev-window-id" ] || [ "$root/scripts/dev-window-id.swift" -nt "$tools/dev-window-id" ]; then
    mkdir -p "$tools"
    xcrun swiftc -O "$root/scripts/dev-window-id.swift" -o "$tools/dev-window-id"
  fi
  while :; do
    local pid id
    pid=$(dev_pid)
    if [ -n "$pid" ]; then
      id=$("$tools/dev-window-id" "$pid" 2>/dev/null || true)
      [ -n "$id" ] && { echo "$id"; return; }
    fi
    [ "$SECONDS" -lt "$deadline" ] || { echo "dev-ui: no window for the development app" >&2; exit 1; }
    sleep 0.3
  done
}

case "$mode" in
  build)
    build
    ;;
  run)
    build
    quit_pid "$(installed_pid)"
    quit_pid "$(dev_pid)"
    open -n "$app"
    window_id >/dev/null
    echo "dev-ui: running $app"
    ;;
  shot)
    out=${2:-$derived/last.png}
    mkdir -p "$(dirname "$out")"
    screencapture -x -l "$(window_id)" "$out"
    echo "dev-ui: $out"
    ;;
  *)
    echo "usage: scripts/dev-ui.sh build|run|shot [png]" >&2
    exit 2
    ;;
esac
