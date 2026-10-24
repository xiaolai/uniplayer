# UniPlayer

A macOS video player built on mpv, with a library-first interface.

## Personal project

UniPlayer is a personal project, published for personal use. Builds are made
for its author's own machines; there is no support commitment, no roadmap, and
no promise that a change will suit anyone else's setup. Issues and pull
requests may go unanswered.

The current development version is 0.2.0 (build 15). Release builds use Developer ID signing
and Apple notarization.

## Install

```sh
brew install --cask xiaolai/tap/uniplayer
```

Requires macOS 27 or later. The universal build contains Apple silicon and
Intel binaries. Release builds are Developer ID signed and notarized, with stapled tickets.

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

Run `python3 scripts/release_local.py --check` from the main checkout to check
readiness, then `python3 scripts/release_local.py` to release using this Mac's
Keychain and saved GitHub login. The command builds and verifies a signed,
notarized universal package, pushes its source/tag, publishes it, updates
Homebrew, and removes older published releases after verification. Git tags
are retained. No GitHub release Action or cloud signing secrets are needed.

See [RELEASING.md](RELEASING.md) for setup, artifact paths and recovery. The
workspace's `./scripts/release.sh` remains a package-only fallback.
