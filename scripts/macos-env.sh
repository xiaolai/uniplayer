# Sourced, not run: the build environment ffmpeg-sys needs on macOS.
#
# .cargo/config.toml points FFMPEG_DIR and LIBCLANG_PATH at the Windows SDK
# layout (src-tauri/ffmpeg, src-tauri/tools), so on macOS both have to come from
# here. Sourced by scripts/tauri.mjs (`npm run tauri …`), macos-dev.sh and
# macos-build.sh, so none of them can drift from the others.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export FFMPEG_DIR="$repo_root/src-tauri/ffmpeg-macos"
[ -d "$FFMPEG_DIR/lib" ] || {
  echo "no FFmpeg SDK in $FFMPEG_DIR — run scripts/fetch-macos-libs.sh" >&2
  exit 1
}

# libclang lives beside the active toolchain's clang — under the Command Line
# Tools on some machines and inside Xcode.app on others, so a fixed path to
# either one breaks the build on the other. An explicit LIBCLANG_PATH wins.
if [ -z "${LIBCLANG_PATH:-}" ]; then
  LIBCLANG_PATH="$(dirname "$(dirname "$(xcrun --find clang)")")/lib"
fi
[ -f "$LIBCLANG_PATH/libclang.dylib" ] || {
  echo "no libclang.dylib in $LIBCLANG_PATH — install Xcode or its Command Line Tools, or set LIBCLANG_PATH" >&2
  exit 1
}
export LIBCLANG_PATH
