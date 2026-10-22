#!/bin/bash

# universal | arm64 | x86_64
ARCH="universal"
# github | iina (use iina to get the binary included in the latest release)
YT_DLP_SOURCE="github"
PARALLEL_DOWNLOADS=5
SKIP_PLUGINS=false
WRITE_LOCK=false

DYLIBS_DOWNLOAD_PATH="https://iina.io/dylibs/${ARCH}"
YT_DLP_DOWNLOAD_PATH="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

printUsageHelp() {
  echo
  echo -e "${BLUE}Usage:${NC}"
  echo -e "    ${GREEN}$0 [-h|--help]:${NC}           Displays this help message"
  echo -e "    ${GREEN}$0 [--arch] <ARCH>:${NC}       Architecture to download dylibs for: universal | arm64 | x86_64"
  echo -e "    ${GREEN}$0 [--yt-dlp-src] <SRC>:${NC}  Source to download youtube-dl from: github | iina"
  echo -e "    ${GREEN}$0 [--parallel] <N>:${NC}      Number of parallel downloads (default: 5)"
  echo -e "    ${GREEN}$0 [--skip-plugins]:${NC}      Skip downloading official plugins"
  echo -e "    ${GREEN}$0 [--write-lock]:${NC}         Write the dependency lock for the selected architecture"
  echo
}

realpath() (
  OURPWD=$PWD
  cd "$(dirname "$1")" || exit
  LINK=$(readlink "$(basename "$1")")
  while [ "$LINK" ]; do
    cd "$(dirname "$LINK")" || exit
    LINK=$(readlink "$(basename "$1")")
  done
  REALPATH="$PWD/$(basename "$1")"
  cd "$OURPWD" || exit
  echo "$REALPATH"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    printUsageHelp
    exit 0
    ;;
  --arch)
    if [[ -z "$2" || "$2" == -* ]]; then
      echo -e "${RED}You need to specify an architecture when using --arch${NC}" >&2
      printUsageHelp
      exit 1
    fi
    ARCH=$2
    shift 2
    ;;
  --arch=*)
    ARCH=${1#*=}
    if [[ -z "$ARCH" ]]; then
      echo -e "${RED}You need to specify an architecture when using --arch${NC}" >&2
      printUsageHelp
      exit 1
    fi
    shift
    ;;
  --yt-dlp-src)
    if [[ -z "$2" || "$2" == -* ]]; then
      echo -e "${RED}You need to specify a source when using --yt-dlp-src${NC}" >&2
      printUsageHelp
      exit 1
    fi
    YT_DLP_SOURCE=$2
    shift 2
    ;;
  --yt-dlp-src=*)
    YT_DLP_SOURCE=${1#*=}
    if [[ -z "$YT_DLP_SOURCE" ]]; then
      echo -e "${RED}You need to specify a source when using --yt-dlp-src${NC}" >&2
      printUsageHelp
      exit 1
    fi
    shift
    ;;
  --parallel)
    if [[ -z "$2" || "$2" == -* ]]; then
      echo -e "${RED}You need to specify a number of parallel downloads when using --parallel${NC}" >&2
      printUsageHelp
      exit 1
    fi
    PARALLEL_DOWNLOADS=$2
    shift 2
    ;;
  --parallel=*)
    PARALLEL_DOWNLOADS=${1#*=}
    if [[ -z "$PARALLEL_DOWNLOADS" ]]; then
      echo -e "${RED}You need to specify a number of parallel downloads when using --parallel${NC}" >&2
      printUsageHelp
      exit 1
    fi
    shift
    ;;
  --skip-plugins)
    SKIP_PLUGINS=true
    shift
    ;;
  --write-lock)
    WRITE_LOCK=true
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo -e "${RED}Unknown option: $1${NC}" >&2
    printUsageHelp
    exit 1
    ;;
  *)
    echo -e "${RED}Unexpected argument: $1${NC}" >&2
    printUsageHelp
    exit 1
    ;;
  esac
done
if [[ $# -gt 0 ]]; then
  echo -e "${RED}Unexpected argument: $1${NC}" >&2
  printUsageHelp
  exit 1
fi

case $YT_DLP_SOURCE in
github)
  YT_DLP_DOWNLOAD_PATH="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
  ;;
iina)
  YT_DLP_DOWNLOAD_PATH="https://iina.io/dylibs/youtube-dl"
  ;;
*)
  echo -e "${RED}Invalid youtube-dl source: $YT_DLP_SOURCE${NC}"
  printUsageHelp
  exit 1
  ;;
esac

case $ARCH in
universal | arm64 | x86_64)
  DYLIBS_DOWNLOAD_PATH="https://iina.io/dylibs/${ARCH}"
  ;;
*)
  echo -e "${RED}Invalid architecture: $ARCH${NC}"
  printUsageHelp
  exit 1
  ;;
esac

SCRIPT_PATH=$(realpath "$0")
# This script lives in <repository root>/other/, so the root is two levels up.
# Deriving it from the script's own path keeps the script working when the
# checkout directory is not named after the project.
ROOT_PATH=$(dirname "$(dirname "$SCRIPT_PATH")")

if [[ ! -d "$ROOT_PATH/deps" ]]; then
  echo -e "${RED}Unable to locate the repository root at '$ROOT_PATH'.${NC}" >&2
  exit 1
fi

DEPS_PATH="$ROOT_PATH/deps"
LIB_PATH="$DEPS_PATH/lib"
EXEC_PATH="$DEPS_PATH/executable"
PLUGIN_PATH="$DEPS_PATH/plugins"
YT_DLP_PATH="$EXEC_PATH/youtube-dl"

LOCK_PATH="$ROOT_PATH/other/dylibs-${ARCH}.lock"

if [[ "$WRITE_LOCK" == true ]]; then
  if [[ ! -d "$LIB_PATH" ]]; then
    echo -e "${RED}No deps/lib directory to lock.${NC}" >&2
    exit 1
  fi
  {
    echo "# UniPlayer dependency lock — ${ARCH}"
    echo "# Generated from deps/ on $(date -u +%Y-%m-%d). Regenerate with: other/download_libs.sh --write-lock --arch ${ARCH}"
    echo "# Source: ${DYLIBS_DOWNLOAD_PATH} and ${YT_DLP_DOWNLOAD_PATH}"
    echo "# The upstream URLs are mutable; these digests pin the exact artifacts."
    echo "# <sha256>  <path>"
    for file in "$LIB_PATH"/*; do
      [[ -f "$file" ]] || continue
      printf "%s  %s\n" "$(shasum -a 256 "$file" | awk '{print $1}')" "$(basename "$file")"
    done
    if [[ -f "$YT_DLP_PATH" ]]; then
      printf "%s  executable/youtube-dl-github\n" "$(shasum -a 256 "$YT_DLP_PATH" | awk '{print $1}')"
    fi
  } > "$LOCK_PATH"
  echo -e "${GREEN}Wrote ${LOCK_PATH}${NC}"
  exit 0
fi

if [[ ! -f "$LOCK_PATH" ]]; then
  echo -e "${RED}No dependency lock for ${ARCH}: ${LOCK_PATH}${NC}" >&2
  echo -e "${RED}Review the dependencies, then run: $0 --write-lock --arch ${ARCH}${NC}" >&2
  exit 1
fi

mkdir -p "$LIB_PATH"

download_verified_file() {
  local expected="$1"
  local file="$2"
  local tmp="${LIB_PATH}/${file}.download"
  echo -e "${YELLOW}Downloading ${file}...${NC}"
  if ! curl -fsSL "${DYLIBS_DOWNLOAD_PATH}/${file}" -o "$tmp"; then
    echo -e "${RED}Failed to download ${file}.${NC}" >&2
    rm -f "$tmp"
    return 1
  fi
  local actual
  actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo -e "${RED}Checksum mismatch for ${file}: expected ${expected}, got ${actual}.${NC}" >&2
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "${LIB_PATH}/${file}"
  echo -e "${GREEN}Verified ${file}${NC}"
}

export -f download_verified_file
export DYLIBS_DOWNLOAD_PATH
export LIB_PATH
export YELLOW
export GREEN
export RED
export NC

entries=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  file=${line#*  }
  hash=${line%%  *}
  [[ "$file" == "executable/"* ]] && continue
  entries+=("$hash $file")
done < "$LOCK_PATH"

if [[ ${#entries[@]} -eq 0 ]]; then
  echo -e "${RED}The dependency lock lists no libraries.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Starting verified downloads in parallel...${NC}"
if ! printf "%s\n" "${entries[@]}" | xargs -n 2 -P "$PARALLEL_DOWNLOADS" bash -c 'download_verified_file "$@"' _; then
  echo -e "${RED}One or more dependency downloads failed.${NC}" >&2
  exit 1
fi

mkdir -p "$EXEC_PATH"
echo -e "${YELLOW}Downloading yt-dlp...${NC}"

YT_DLP_LOCK_KEY="executable/youtube-dl-${YT_DLP_SOURCE}"
ytdl_hash=$(awk -v key="$YT_DLP_LOCK_KEY" '$2 == key {print $1}' "$LOCK_PATH")
if [[ -z "$ytdl_hash" ]]; then
  echo -e "${RED}No lock entry for ${YT_DLP_LOCK_KEY}.${NC}" >&2
  echo -e "${RED}Only the pinned source is accepted; update the lock deliberately.${NC}" >&2
  exit 1
fi

ytdl_tmp="${YT_DLP_PATH}.download"
if ! curl -fsSL "$YT_DLP_DOWNLOAD_PATH" -o "$ytdl_tmp"; then
  echo -e "${RED}Failed to download yt-dlp.${NC}" >&2
  rm -f "$ytdl_tmp"
  exit 1
fi
ytdl_actual=$(shasum -a 256 "$ytdl_tmp" | awk '{print $1}')
if [[ "$ytdl_actual" != "$ytdl_hash" ]]; then
  echo -e "${RED}Checksum mismatch for yt-dlp: expected ${ytdl_hash}, got ${ytdl_actual}.${NC}" >&2
  rm -f "$ytdl_tmp"
  exit 1
fi
chmod +x "$ytdl_tmp"
mv "$ytdl_tmp" "$YT_DLP_PATH"
echo -e "${GREEN}Verified yt-dlp${NC}"

mkdir -p "$PLUGIN_PATH"

if [[ "$SKIP_PLUGINS" == true ]]; then
  echo -e "${YELLOW}Skipping official plugin downloads.${NC}"
  echo -e "${GREEN}All downloads completed.${NC}"
  exit 0
fi

fetch_latest_plugin_asset() {
  local repo="$1"
  local response_file
  local status_code
  local curl_args=()

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  response_file=$(mktemp) || return 1
  status_code=$(curl -s -L "${curl_args[@]}" -o "$response_file" -w "%{http_code}" "https://api.github.com/repos/${repo}/releases/latest") || {
    echo -e "${RED}Failed to contact GitHub for ${repo}.${NC}" >&2
    rm -f "$response_file"
    return 1
  }

  if [[ "$status_code" -lt 200 || "$status_code" -ge 300 ]]; then
    echo -e "${RED}GitHub API returned HTTP ${status_code} for ${repo}.${NC}" >&2
    python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace").strip()
if not text:
    raise SystemExit(0)
try:
    payload = json.loads(text)
except json.JSONDecodeError:
    print(text[:240], file=sys.stderr)
    raise SystemExit(0)
message = payload.get("message")
if message:
    print(message, file=sys.stderr)
' "$response_file"
    rm -f "$response_file"
    return 1
  fi

  python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
try:
    release = json.loads(text)
except json.JSONDecodeError as exc:
    print(f"Failed to decode GitHub API response as JSON: {exc}", file=sys.stderr)
    preview = text.strip()
    if preview:
        print(preview[:240], file=sys.stderr)
    raise SystemExit(1)
assets = [asset for asset in release.get("assets", []) if asset.get("name", "").endswith(".iinaplgz")]
if not assets:
    message = release.get("message")
    if message:
        print(message, file=sys.stderr)
    else:
        print("Latest release does not contain a .iinaplgz asset.", file=sys.stderr)
    raise SystemExit(1)
asset = assets[0]
print(asset["name"])
print(asset["browser_download_url"])
' "$response_file"
  local status=$?
  rm -f "$response_file"
  return $status
}

download_plugin() {
  local repo="$1"
  local prefix="$2"
  local asset_info
  local asset_name
  local asset_url
  local tmp_path

  echo -e "${YELLOW}Downloading latest plugin release for ${repo}...${NC}"
  asset_info=$(fetch_latest_plugin_asset "$repo") || {
    echo -e "${RED}Failed to fetch the latest plugin asset for ${repo}.${NC}" >&2
    return 1
  }

  asset_name=$(printf "%s\n" "$asset_info" | sed -n "1p")
  asset_url=$(printf "%s\n" "$asset_info" | sed -n "2p")
  tmp_path="${PLUGIN_PATH}/${asset_name}.download"

  curl -s -f -L "$asset_url" -o "$tmp_path" || {
    echo -e "${RED}Failed downloading ${asset_name}.${NC}" >&2
    rm -f "$tmp_path"
    return 1
  }

  find "$PLUGIN_PATH" -maxdepth 1 -type f -name "${prefix}-*.iinaplgz" -delete
  mv "$tmp_path" "${PLUGIN_PATH}/${asset_name}"
  echo -e "${GREEN}Downloaded ${asset_name}${NC}"
}

download_plugin "iina/plugin-online-media" "uniplayer-plugin-ytdl" || exit 1
download_plugin "iina/plugin-userscript" "uniplayer-plugin-userscript" || exit 1
download_plugin "iina/plugin-opensub" "uniplayer-plugin-opensub" || exit 1

echo -e "${GREEN}All downloads completed.${NC}"
