#!/usr/bin/env bash
#
# Rebuild every icon the app ships from the one hand-drawn glyph.
#
#   scripts/build-icons.sh           regenerate everything in place
#   scripts/build-icons.sh --check   regenerate into a temp dir, compare with what is committed,
#                                    exit 1 if anything is stale. Writes nothing to the repo.
#
# The ONLY artwork anybody edits is src-tauri/icons/icon-master.svg (plus the colours in
# UniPlayer.icon/icon.json). Everything below is derived, and hand-editing a derived file is
# always wrong: the next run overwrites it, and until then two surfaces disagree.
#
# Three treatments, because the platforms really do differ:
#
#   icon-master-macos.svg   824 tile inside a 1024 canvas, with its own shadow. Feeds icon.icns
#                           ONLY — the flat fallback for every macOS before 26, which draws a
#                           bundle .icns exactly as given.
#
#   UniPlayer.icon          the layered macOS 26+ icon: the glyph alone on a transparent 1024
#                           canvas (Assets/glyph.png) plus a fill in icon.json. The system masks,
#                           fills, lights and shadows it, so none of that is in the pixels.
#                           Compiled by actool into icons/Assets.car, which the bundle carries
#                           and CFBundleIconName (src-tauri/Info.plist) points at.
#
#   icon-master-tile.svg    full-bleed cream tile, no gutter. Windows neither masks nor insets,
#                           so the icon brings its own shape. Feeds icon.ico, the PNG set and
#                           the favicon. (The title-bar mark in TopBar.svelte is the bare glyph.)
#
# Why the Windows icon is a tile and not the bare glyph: the glyph's darkest face (#1f3c86) is
# 1.6:1 against a dark taskbar, so on Windows dark mode a third of the mark disappeared. On the
# cream tile the three faces are 8.1 / 3.2 / 1.4 :1 against the tile, and the tile itself is
# ~14:1 against a dark taskbar — legible on either theme.
#
# Why the .icon's DARK fill is the same cream: the same arithmetic. A dark tile puts the navy
# face at 1.6–1.9:1 (measured with ictool on a #1f2024 fill and on the system's own automatic
# dark), and leaving the dark fill out does not avoid it — the system then darkens the tile to
# near-black by itself. The mark was drawn for a light ground; keeping one keeps it whole.
#
# Every tool below can fail quietly, so each output is asserted, not assumed:
#   - rsvg-convert emits 3-channel RGB for an opaque image and Tauri hard-rejects a non-RGBA
#     bundle icon (`icon … is not RGBA`, failing the crate build) — every PNG goes through
#     `magick PNG32:` and is then checked for an alpha channel.
#   - actool exits 0 and writes nothing on a bad manifest — the catalogue's existence and the
#     app-icon name inside it are both checked with assetutil.
#   - a layered icon can compile clean and render black, or render the tile with no mark — the
#     compiled icon is rendered with ictool and the pixels are checked for both.
#
# Requires macOS with Xcode 26+ (actool, ictool — the Command Line Tools alone have neither),
# plus rsvg-convert and ImageMagick 7 (`brew install librsvg imagemagick`) and node.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode=write
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  *) echo "usage: scripts/build-icons.sh [--check]" >&2; exit 2 ;;
esac

die() { echo "build-icons: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only (iconutil, actool and ictool are Apple tools)"

for tool in node rsvg-convert magick iconutil sips assetutil; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool '$tool'"
done
actool="$(xcrun --find actool 2>/dev/null)" || die "actool not found — install Xcode 26+ (the Command Line Tools do not ship it)"
# Not `xcrun ictool`: that resolves to a different binary of the actool family.
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || die "ictool not found at $ictool — install Xcode 26+"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Where the outputs go: the repository, or a scratch tree shaped like it for --check.
if [[ "$mode" == check ]]; then out="$work/out"; else out="$repo"; fi
icons="$out/src-tauri/icons"
mkdir -p "$icons" "$out/static"

# The generated files, relative to the repo root. --check compares exactly this list, and the
# final assertion below fails if any of them was not written.
generated=(
  src-tauri/icons/icon-master-tile.svg
  src-tauri/icons/icon-master-macos.svg
  src/lib/components/TopBar.svelte
  src-tauri/icons/icon.icns
  src-tauri/icons/icon.ico
  src-tauri/icons/UniPlayer.icon/Assets/glyph.png
  src-tauri/icons/Assets.car
  src-tauri/icons/icon-master.png
  src-tauri/icons/32x32.png
  src-tauri/icons/64x64.png
  src-tauri/icons/128x128.png
  src-tauri/icons/128x128@2x.png
  src-tauri/icons/icon.png
  src-tauri/icons/Square30x30Logo.png
  src-tauri/icons/Square44x44Logo.png
  src-tauri/icons/Square71x71Logo.png
  src-tauri/icons/Square89x89Logo.png
  src-tauri/icons/Square107x107Logo.png
  src-tauri/icons/Square142x142Logo.png
  src-tauri/icons/Square150x150Logo.png
  src-tauri/icons/Square284x284Logo.png
  src-tauri/icons/Square310x310Logo.png
  src-tauri/icons/StoreLogo.png
  static/favicon.png
)
# Anything already there is removed first, so a step that silently writes nothing cannot leave
# the previous run's file behind looking like a success.
for f in "${generated[@]}"; do
  [[ "$f" == src/lib/components/TopBar.svelte ]] || rm -f "$out/$f"
done

# render <svg> <px> <out.png> — rasterise at the target size, then force RGBA.
render() {
  rsvg-convert -w "$2" -h "$2" "$1" -o "$work/r.png"
  magick "$work/r.png" -strip PNG32:"$3"
}

# --- 1. the SVGs, from the one glyph ----------------------------------------------------------
echo "==> deriving SVGs from icon-master.svg"
node "$repo/scripts/icons/derive-svgs.mjs" "$repo" "$out" "$work"
tile_svg="$icons/icon-master-tile.svg"
macos_svg="$icons/icon-master-macos.svg"

# --- 2. macOS flat fallback: the full .icns ladder --------------------------------------------
# Every rung is rendered at its own size rather than downsampled from 1024: that is what keeps
# 16 and 32 crisp. A missing rung is what makes a Retina Dock upscale and look soft.
echo "==> icon.icns (from icon-master-macos.svg)"
iconset="$work/UniPlayer.iconset"
mkdir -p "$iconset"
for entry in \
  icon_16x16.png:16 icon_16x16@2x.png:32 \
  icon_32x32.png:32 icon_32x32@2x.png:64 \
  icon_128x128.png:128 icon_128x128@2x.png:256 \
  icon_256x256.png:256 icon_256x256@2x.png:512 \
  icon_512x512.png:512 icon_512x512@2x.png:1024; do
  render "$macos_svg" "${entry##*:}" "$iconset/${entry%%:*}"
done
iconutil -c icns "$iconset" -o "$icons/icon.icns"

# --- 3. macOS 26+: the layered icon and its catalogue -----------------------------------------
echo "==> UniPlayer.icon layer (glyph alone, 1024, RGBA)"
dot_icon="$icons/UniPlayer.icon"
mkdir -p "$dot_icon/Assets"
if [[ "$mode" == check ]]; then cp "$repo/src-tauri/icons/UniPlayer.icon/icon.json" "$dot_icon/"; fi
[[ -f "$dot_icon/icon.json" ]] || die "missing $dot_icon/icon.json"
# PNG, not SVG: an SVG layer loses the system's specular and shadow, and one with filters
# compiles clean and renders black.
render "$work/layer.svg" 1024 "$dot_icon/Assets/glyph.png"

# Every image-name must resolve: a missing one is another way actool exits 0 having done nothing.
while read -r asset; do
  [[ -z "$asset" || -f "$dot_icon/Assets/$asset" ]] || die "icon.json references missing asset '$asset'"
done < <(sed -n 's/.*"image-name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dot_icon/icon.json")

echo "==> Assets.car (actool)"
# The input must be the .icon itself — a folder containing it, or an .xcassets around it, are
# both accepted and compile nothing. --minimum-deployment-target 26.0 selects the glass renderer;
# --output-partial-info-plist is required for an app icon even though the plist is discarded.
# --app-icon is the third of three names that must agree: the .icon's basename, this, and
# CFBundleIconName in src-tauri/Info.plist.
mkdir -p "$work/car"
"$actool" "$dot_icon" \
  --compile "$work/car" \
  --output-partial-info-plist "$work/car/partial.plist" \
  --app-icon UniPlayer \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --platform macosx \
  --output-format human-readable-text --notices --warnings --errors
[[ -s "$work/car/Assets.car" ]] || die "actool produced no Assets.car (it exits 0 on a malformed icon.json — check its keys and every image-name)"
assetutil --info "$work/car/Assets.car" | grep -q '"Name" : "UniPlayer"' \
  || die "Assets.car has no asset named 'UniPlayer' — CFBundleIconName would resolve to nothing and macOS would fall back to the .icns without a word"
# actool also writes a UniPlayer.icns carrying only 16pt and 128pt. It is not shipped; the
# hand-built icon.icns above keeps the full ladder.
cp "$work/car/Assets.car" "$icons/Assets.car"

# The catalogue proves nothing about the picture, so render the .icon and look at the pixels.
# Two separate failures: a near-black tile (unsupported layer content), and a clean tile with no
# mark on it (a layer occluded or empty).
for rendition in Default Dark; do
  "$ictool" "$dot_icon" --export-image --output-file "$work/ict-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 256 --height 256 --scale 1 >/dev/null
  [[ -s "$work/ict-$rendition.png" ]] || die "ictool rendered nothing for the $rendition rendition"
  mean="$(magick "$work/ict-$rendition.png" -alpha off -colorspace gray -format '%[fx:mean]' info:)"
  blue="$(magick "$work/ict-$rendition.png" -alpha off -fx '(b-r)>0.2' -format '%[fx:mean]' info:)"
  echo "    $rendition: mean luminance $mean, glyph-blue pixels $blue"
  awk -v m="$mean" 'BEGIN{exit !(m > 0.5)}' || die "$rendition rendition is dark (mean $mean) — the cream tile did not render"
  awk -v b="$blue" 'BEGIN{exit !(b > 0.15)}' || die "$rendition rendition shows no glyph (blue fraction $b)"
done

# --- 4. Windows: the .ico, each member rendered at its own size --------------------------------
echo "==> icon.ico (16/24/32/48/64/128/256, from icon-master-tile.svg)"
members=()
for size in 16 24 32 48 64 128 256; do
  render "$tile_svg" "$size" "$work/ico-$size.png"
  members+=("$work/ico-$size.png")
done
node "$repo/scripts/icons/make-ico.mjs" "$icons/icon.ico" "${members[@]}"

# --- 5. the PNG set and the favicon, from the same tile ---------------------------------------
# 32/128/128@2x are Tauri's bundle.icon entries (and the window icon off Windows); the Square*
# and StoreLogo set is the Windows Store tile ladder.
echo "==> PNG set, Square*Logo, favicon (from icon-master-tile.svg)"
for entry in 32x32.png:32 64x64.png:64 128x128.png:128 128x128@2x.png:256 icon.png:512 \
  Square30x30Logo.png:30 Square44x44Logo.png:44 Square71x71Logo.png:71 Square89x89Logo.png:89 \
  Square107x107Logo.png:107 Square142x142Logo.png:142 Square150x150Logo.png:150 \
  Square284x284Logo.png:284 Square310x310Logo.png:310 StoreLogo.png:50; do
  render "$tile_svg" "${entry##*:}" "$icons/${entry%%:*}"
done
render "$tile_svg" 128 "$out/static/favicon.png"
# The bare glyph at 1024: a preview of the master itself, not consumed by any build.
render "$repo/src-tauri/icons/icon-master.svg" 1024 "$icons/icon-master.png"

# --- 6. assertions on what was written ----------------------------------------------------------
echo "==> checking outputs"
for f in "${generated[@]}"; do
  [[ -s "$out/$f" ]] || die "$f was not written"
  if [[ "$f" == *.png ]]; then
    channels="$(magick identify -format '%[channels]' "$out/$f")"
    [[ "$channels" == srgba* ]] || die "$f is '$channels', not RGBA — Tauri rejects it"
  fi
done

# The glyph's size is the reason this script was rewritten; assert it on the layer, where the
# alpha bounding box IS the glyph. 0.75 of the canvas tall, centred.
read -r gw gh gx gy < <(magick "$dot_icon/Assets/glyph.png" -alpha extract -threshold 50% \
  -format '%@' info: | awk -F'[x+]' '{print $1, $2, $3, $4}')
awk -v w="$gw" -v h="$gh" -v x="$gx" -v y="$gy" 'BEGIN{
  hf=h/1024; wf=w/1024; cx=(x+w/2)/1024; cy=(y+h/2)/1024
  printf "    layer glyph %.3f wide x %.3f tall, centre (%.3f, %.3f)\n", wf, hf, cx, cy
  exit !(hf>0.74 && hf<0.76 && wf>0.67 && wf<0.70 && cx>0.49 && cx<0.51 && cy>0.49 && cy<0.51)
}' || die "layer glyph is off its 0.75 target — check GLYPH_H in derive-svgs.mjs"

# The .icns must carry the whole ladder. iconutil is fine for ENUMERATING members (it is its
# pixel decode of the legacy small members that cannot be trusted); sips reads the 1024 through
# ImageIO, the path macOS itself uses.
[[ "$(iconutil -c iconset "$icons/icon.icns" -o "$work/rt.iconset" && ls "$work/rt.iconset" | wc -l | tr -d ' ')" == 10 ]] \
  || die "icon.icns does not carry the 10-member ladder"
[[ "$(sips -g pixelWidth "$icons/icon.icns" | awk '/pixelWidth/{print $2}')" == 1024 ]] \
  || die "icon.icns has no 1024 representation"

# --- 7. --check: compare with what is committed ------------------------------------------------
if [[ "$mode" == check ]]; then
  echo "==> comparing with the committed files"
  # Assets.car is not byte-reproducible: actool stamps a timestamp and names its flattened
  # preview renditions with a fresh UUID (and so a fresh digest) on every run. The layer image,
  # the colours and the gradient are stable, so compare the decoded catalogue with only those
  # volatile fields masked.
  car_info() {
    assetutil --info "$1" | awk '
      /"Timestamp"/ { next }
      /"RenditionName"/ { sys = /NSAppearanceNameSystem_/; if (sys) { print "  <flattened rendition>"; next } }
      /"SHA1Digest"/ && sys { next }
      /^  [{}]/ { sys = 0 }
      { print }'
  }
  stale=0
  for f in "${generated[@]}"; do
    if [[ "$f" == *.car ]]; then
      diff -q <(car_info "$repo/$f") <(car_info "$out/$f") >/dev/null || { echo "  STALE $f"; stale=1; }
    else
      cmp -s "$repo/$f" "$out/$f" || { echo "  STALE $f"; stale=1; }
    fi
  done
  [[ "$stale" == 0 ]] || die "committed icons do not match their source — run scripts/build-icons.sh"
  echo "build-icons: every committed icon matches its source (${#generated[@]} files)"
  exit 0
fi

echo "build-icons: done (${#generated[@]} files)"
