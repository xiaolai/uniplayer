# UniPlayer

A macOS video player built on mpv, with a library-first interface.

## Personal project

UniPlayer is a personal project, published for personal use. Builds are made
for its author's own machines; there is no support commitment, no roadmap, and
no promise that a change will suit anyone else's setup. Issues and pull
requests may go unanswered.

The current version is 0.2.4 (build 19). Release builds use Developer ID signing
and Apple notarization.

## Install

```sh
brew install --cask xiaolai/tap/uniplayer
```

Requires macOS 27 or later. The universal build contains Apple silicon and
Intel binaries. Release builds are Developer ID signed and notarized, with stapled tickets.

## HUD window

The HUD is UniPlayer's compact playback window (formerly called Music Mode).
While playing in the library, use the HUD button in the player controls or
**Video → Switch to HUD Window**. The library stays open; exiting the HUD
returns to the standalone player window.

The release DMG also contains the tiny **UniPlayer HUD.app** Finder handler.
Install it next to UniPlayer, and Finder's **Open With** menu offers
“UniPlayer HUD”, which opens the selected files in the HUD. Install both apps;
the Homebrew cask must ship both.

## Relationship to IINA

UniPlayer began as a fork of [IINA](https://github.com/iina/iina), and that
origin is why it exists at all. The interface has since been restructured: the
library, inline player, channels and AI inspector are new work, and the
presentation layer no longer follows upstream's window model.

Upstream is no longer tracked. This repository has no `upstream` remote and does
not merge IINA changes; fixes and features are made here. The engine and plugin
API remain IINA's, and the original copyright notices and third-party licences
in [`uniplayer/Credits.rtf`](uniplayer/Credits.rtf) are retained.

## License

**GPL-3.0-or-later.** See [LICENSE](LICENSE). UniPlayer is derived from IINA,
copyright Collider LI and contributors. If you distribute a build, you must
publish the corresponding source under the GPL.

## Release

From the workspace root, run `./scripts/release.sh`. It prepares the local
notarization profile, then builds, signs, notarizes, staples and verifies the
universal app and DMG. It uses this Mac's Keychain; it does not publish.

Publish the verified DMG/checksum with `gh release`, then update the Homebrew
cask's version and SHA-256. Verify the new release and cask before deleting older
published releases. Keep Git tags.
