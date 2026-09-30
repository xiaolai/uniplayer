#!/usr/bin/env node
// Assemble a multi-resolution .ico from PNGs, each stored as the PNG it already is.
//
//   node scripts/icons/make-ico.mjs <out.ico> <16.png> <24.png> ... <256.png>
//
// Called by scripts/build-icons.sh. ImageMagick would do this in one line, but it writes every
// member as an uncompressed BMP — 270 KB for the 256 member alone — where the ICO container has
// taken PNG members since Vista. Every member here is PNG, which is also the format the icon the
// player shipped under its previous name used, so this is the encoding the Windows build (the
// resource compiler and NSIS) is already known to accept.
//
// Each member is rendered from the SVG at its own size by the caller, never downsampled from
// one bitmap: that is what keeps 16 and 24 sharp.

import { readFileSync, writeFileSync } from "node:fs";

const [out, ...inputs] = process.argv.slice(2);
if (!out || inputs.length === 0) {
  console.error("usage: make-ico.mjs <out.ico> <png> [<png> ...]");
  process.exit(2);
}

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const members = inputs.map((path) => {
  const data = readFileSync(path);
  if (!data.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error(`${path}: not a PNG`);
  // IHDR is always the first chunk: width at byte 16, height at 20, bit depth 24, colour type 25.
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  const depth = data[24];
  const colourType = data[25];
  if (width !== height) throw new Error(`${path}: ${width}x${height}, expected a square`);
  if (width > 256) throw new Error(`${path}: ${width}px, an ICO member caps at 256`);
  // 6 = truecolour with alpha. Anything else loses the tile's transparent corners.
  if (depth !== 8 || colourType !== 6) throw new Error(`${path}: not 8-bit RGBA (depth ${depth}, type ${colourType})`);
  return { size: width, data };
});

members.sort((a, b) => a.size - b.size);
const sizes = members.map((m) => m.size);
if (new Set(sizes).size !== sizes.length) throw new Error(`duplicate member sizes: ${sizes.join(", ")}`);

const header = Buffer.alloc(6);
header.writeUInt16LE(0, 0); // reserved
header.writeUInt16LE(1, 2); // type: icon
header.writeUInt16LE(members.length, 4);

let offset = 6 + 16 * members.length;
const directory = members.map(({ size, data }) => {
  const entry = Buffer.alloc(16);
  entry[0] = size === 256 ? 0 : size; // 256 is written as 0
  entry[1] = size === 256 ? 0 : size;
  entry[2] = 0; // palette size: none
  entry[3] = 0; // reserved
  entry.writeUInt16LE(1, 4); // colour planes
  entry.writeUInt16LE(32, 6); // bits per pixel
  entry.writeUInt32LE(data.length, 8);
  entry.writeUInt32LE(offset, 12);
  offset += data.length;
  return entry;
});

const ico = Buffer.concat([header, ...directory, ...members.map((m) => m.data)]);
writeFileSync(out, ico);
console.log(`  wrote ${out}: ${members.length} PNG members (${sizes.join(", ")}), ${ico.length} bytes`);
