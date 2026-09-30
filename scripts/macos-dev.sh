#!/usr/bin/env bash
# `tauri dev` on macOS, with the FFmpeg and libclang paths from macos-env.sh.
#
#   npm run tauri:macos
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/macos-env.sh"
exec npx tauri dev "$@"
