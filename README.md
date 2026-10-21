# UniPlayer

A macOS video player built on [IINA](https://github.com/iina/iina), with its own
product identity, bundle identifiers and release process. IINA is an mpv-based
player; UniPlayer keeps that engine, its mpv integration and its plugin API, and
is where new features are developed.

## Status

This repository is a fork, not a redistribution of IINA. The user-visible product
is UniPlayer, and the internal target, module, scheme and directory names are
`uniplayer` as well. Two interface names are deliberately unchanged so existing
plugins keep working: the JavaScript plugin global (`iina.*`) and the plugin
package extension (`.iinaplgz`).

## License

UniPlayer is licensed under **GPL-3.0-or-later**. See [LICENSE](LICENSE).
It is derived from IINA, copyright Collider LI and contributors; the original
copyright notices and the third-party licenses in
[`uniplayer/Credits.rtf`](uniplayer/Credits.rtf) are retained. If you distribute
a build, you must publish the corresponding source under the GPL.

## Building

Requirements: macOS, Xcode 27 or later, and the prebuilt media libraries.

```sh
./other/download_libs.sh --skip-plugins

xcodebuild -project uniplayer.xcodeproj -scheme uniplayer -configuration Debug \
  -derivedDataPath /tmp/uniplayer-dd CODE_SIGNING_ALLOWED=NO build
```

`download_libs.sh` fetches libmpv and FFmpeg from the upstream project's binary
host. The build signs ad hoc by default, so no Apple developer account is needed.
For a distributable build, set `DEVELOPMENT_TEAM` in
`Configs/Deployment.xcconfig` and sign with your own identity.

## Rebrand state

| Item | Value |
| --- | --- |
| App bundle ID | `com.lixiaolai.uniplayer` |
| CLI / plugin / extension | `.cli`, `.plugin`, `.OpenInUniPlayer` |
| URL scheme | `uniplayer://` |
| App icons | `uniplayer`, `uniplayer_beta`, `uniplayer_nightly` (Icon Composer) |
| Update feed | Release asset in this repository (`AppData.appcastLink`) |
| Plugin API | Unchanged: `iina.*` and `.iinaplgz` |

Sparkle's public keys were removed from `Info.plist`, so update checks fail closed
until a key pair and a signed appcast are published. `plugins.json` still lists
upstream plugins because the plugin API is unchanged.

## Upstream

Upstream IINA: <https://github.com/iina/iina>. Security fixes and player
improvements from upstream can be merged from the `upstream` remote.
