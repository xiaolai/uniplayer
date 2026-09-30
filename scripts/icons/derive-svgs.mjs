#!/usr/bin/env node
// Derive every icon SVG from the one hand-drawn glyph, `src-tauri/icons/icon-master.svg`.
//
//   node scripts/icons/derive-svgs.mjs <repo root> <output root> <work dir>
//
// Called by scripts/build-icons.sh — run that, not this. Writes, under <output root>:
//
//   src-tauri/icons/icon-master-tile.svg   cream tile, full bleed: Windows, the PNG set, the favicon
//   src-tauri/icons/icon-master-macos.svg  Apple grid (824 tile on 1024, shadow): the flat .icns
//   src/lib/components/TopBar.svelte       the title-bar mark: the bare glyph, rewritten in place
//
// and, under <work dir>, `layer.svg`: the bare glyph on a 1024 canvas that becomes the
// UniPlayer.icon layer. macOS 26+ draws the tile, the glass and the shadow for that one itself.
//
// Every surface places the glyph at the same fraction of its tile, so one number decides how
// big the mark reads everywhere. That is the whole point of generating these rather than
// keeping four hand-edited copies: the title bar, the favicon, the Dock and the taskbar
// cannot drift apart.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

const [repo, out, work] = process.argv.slice(2);
if (!repo || !out || !work) {
  console.error("usage: derive-svgs.mjs <repo root> <output root> <work dir>");
  process.exit(2);
}

function fail(message) {
  console.error(`derive-svgs: ${message}`);
  process.exit(1);
}

// --- the glyph -------------------------------------------------------------------------------

const master = readFileSync(join(repo, "src-tauri/icons/icon-master.svg"), "utf8");

const clips = [...master.matchAll(/<clipPath id="c"><path d="([^"]+)"/g)];
if (clips.length !== 1) fail(`expected one clipPath "c" in icon-master.svg, found ${clips.length}`);
const clip = clips[0][1];

const polygons = [...master.matchAll(/<polygon points="([^"]+)" fill="(#[0-9a-fA-F]{6})"/g)].map(
  (m) => ({ points: m[1], fill: m[2] }),
);
if (polygons.length !== 3) fail(`expected the glyph's three faces in icon-master.svg, found ${polygons.length}`);

// The glyph's ink, in its own units: the clip path's extremes. Left edge x=32.73; right edge is
// the arc centred on (73.53, 50) with r=10; top and bottom are the arcs centred on (42.73,
// 32.22) and (42.73, 67.78), r=10. Checked against a 2560px render: 1636 x 1788 px at 32.19 px
// per unit = 50.82 x 55.54 units. build-icons.sh re-measures every output, so a wrong constant
// here fails the build rather than shipping.
const GLYPH_H = 77.78 - 22.22; // 55.56
// The designer's anchor: `translate(-58 -50)` puts this point at the tile centre.
const ANCHOR = "translate(-58 -50)";

// Glyph height as a fraction of its tile. Cubus's mark measures 0.750 of its tile in height and
// 0.687 in width; at 0.75 in height this glyph lands at 0.686 in width, so the two sit in a
// Dock at the same weight. The previous artwork was 0.41 x 0.38.
const GLYPH_OF_TILE = 0.75;

const scaleFor = (tile) => ((tile * GLYPH_OF_TILE) / GLYPH_H).toFixed(5);

function glyph(cx, cy, tile, clipId) {
  const faces = polygons.map((p) => `<polygon points="${p.points}" fill="${p.fill}"/>`).join("");
  return (
    `<g transform="translate(${cx} ${cy}) scale(${scaleFor(tile)}) ${ANCHOR}">` +
    `<g clip-path="url(#${clipId})">${faces}</g></g>`
  );
}

const clipDef = (id) => `<clipPath id="${id}"><path d="${clip}"/></clipPath>`;

const CREAM = "#f3f0ea";

function header(what) {
  return (
    `<!-- GENERATED from icon-master.svg by scripts/build-icons.sh. Do not edit: change the ` +
    `master or the script. ${what} -->`
  );
}

function write(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  console.log(`  wrote ${path}`);
}

// --- the tile: Windows, the PNG set, the favicon, the title bar ------------------------------
// Full bleed, no gutter: Windows and Linux neither mask nor inset, so the icon carries its own
// shape and should fill its box. rx 112 on 512 is the tile the favicon and title bar already had.

const tile =
  `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">` +
  header("Full-bleed tile: icon.ico, the PNG set, static/favicon.png.") +
  `<defs>${clipDef("c")}</defs>` +
  `<rect width="512" height="512" rx="112" fill="${CREAM}"/>` +
  glyph(256, 256, 512, "c") +
  `</svg>\n`;
write(join(out, "src-tauri/icons/icon-master-tile.svg"), tile);

// --- the flat macOS icon: the .icns every macOS before 26 uses ------------------------------
// The Apple grid: an 824 tile inside a 1024 canvas, its own shadow. A bundle .icns is drawn as
// given on those systems, so the gutter and the shadow have to be in the pixels.

const macos =
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
  header("Apple grid, 824 tile on 1024: icon.icns.") +
  `<defs>${clipDef("c")}` +
  `<filter id="s" x="-20%" y="-20%" width="140%" height="140%">` +
  `<feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/></filter></defs>` +
  `<rect x="100" y="100" width="824" height="824" rx="185.4" fill="${CREAM}" filter="url(#s)"/>` +
  glyph(512, 512, 824, "c") +
  `</svg>\n`;
write(join(out, "src-tauri/icons/icon-master-macos.svg"), macos);

// --- the layered macOS 26+ icon: the glyph alone ---------------------------------------------
// The .icon canvas IS the tile — the system masks it, fills it from icon.json and lights it —
// so the glyph is sized against all 1024, with no background and no shadow of its own.

const layer =
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
  `<defs>${clipDef("c")}</defs>` +
  glyph(512, 512, 1024, "c") +
  `</svg>\n`;
write(join(work, "layer.svg"), layer);

// --- the title-bar mark ----------------------------------------------------------------------
// The bare glyph at 32 units, inline in TopBar.svelte — no tile, filling its box: a nominal
// 40-unit tile puts the glyph's height at 30 of the 32. Its clipPath id must stay `brand-glyph`:
// an inline SVG's ids are document-global, and `c` would collide with anything else on the page.

const topbarPath = "src/lib/components/TopBar.svelte";
const topbar = readFileSync(join(repo, topbarPath), "utf8");
const logo = /<svg class="logo" viewBox="0 0 32 32" aria-hidden="true">[\s\S]*?<\/svg>/g;
const found = topbar.match(logo) ?? [];
if (found.length !== 1) fail(`expected one <svg class="logo"> in ${topbarPath}, found ${found.length}`);
const mark =
  `<svg class="logo" viewBox="0 0 32 32" aria-hidden="true"><defs>${clipDef("brand-glyph")}</defs>` +
  glyph(16, 16, 40, "brand-glyph") +
  `</svg>`;
write(join(out, topbarPath), topbar.replace(logo, () => mark));
