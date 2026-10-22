# UniPlayer

A macOS video player built on mpv, with a library-first interface.

## Personal project

UniPlayer is a personal project, published for personal use. Builds are made
for its author's own machines; there is no support commitment, no roadmap, and
no promise that a change will suit anyone else's setup. Issues and pull
requests may go unanswered.

The current version is 0.1.4 (build 5). Builds are ad hoc signed unless a
development team is configured; see [Building](#building).

## What it does

- **Library.** A local library of folders and files, with posters, metadata and
  playback state. Opening a file plays it in the detail column.
- **One player, three places.** `PlayerCore` owns a single `VideoView` and moves
  it between the player window, the mini player, and the library's inline
  detail. Normal library playback never opens a second window.
- **Inline playback.** An auto-hiding overlay provides transport, timeline,
  volume, track and speed controls. Double-click enters fullscreen; `⌘⇧F`
  toggles a windowed Focus mode; `⌘⇧L` returns playback to the library from the
  detached window.
- **Channels.** A `WKWebView`-based browser for sites whose own pages you want
  to watch in the app, with persistent cookies and AirPlay permission. Pages
  that require DRM stay in the web view.
- **AI inspector.** `⌘⌥I` opens an assistant with explicit context: title,
  timestamp, current subtitle, and the exact text that will be sent. Full local
  paths are redacted unless opted in per request. It speaks to any
  OpenAI-compatible streaming endpoint or the Claude Messages API; the API key
  lives in the Keychain.
- **mpv underneath.** The full engine, its options and its plugin API are still
  there, including the JavaScript global `iina.*` and `.iinaplgz` packages, kept
  unchanged for compatibility.

## Requirements

- macOS 27 or later
- Xcode 27 or later
- The prebuilt media libraries (libmpv, FFmpeg, and the bundled tools), fetched
  by `other/download_libs.sh`

## Building

```sh
./other/download_libs.sh --skip-plugins

xcodebuild -project uniplayer.xcodeproj -scheme uniplayer -configuration Debug \
  -derivedDataPath /tmp/uniplayer-dd CODE_SIGNING_ALLOWED=NO build
```

`download_libs.sh` fetches the mpv/FFmpeg dylibs from the IINA binary host,
because the engine is unchanged. The build signs ad hoc by default, so no Apple
developer account is needed. For a signed build, set `DEVELOPMENT_TEAM` in
`Configs/Deployment.xcconfig` and sign with your own identity.

## Checks

```sh
python3 scripts/check-design-tokens.py --ledger
python3 -m unittest scripts/test_check_design_tokens.py
python3 scripts/validate-browser-extensions.py
xcodebuild -project uniplayer.xcodeproj -scheme uniplayer \
  -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Every appearance value in the interface is a token in
`uniplayer/DesignTokens.swift`; `DESIGN_TOKENS.md` is the generated ledger and
the first command is the gate that keeps hand-rolled values out. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the rule and its exemptions.

## Layout

| Path | Contents |
| --- | --- |
| `uniplayer/` | The app: library, player core, inline player, channels, AI inspector |
| `uniplayerTests/` | Unit tests for presentation, redaction, tools and streaming |
| `uniplayer-cli/` | `uniplayer-cli`, works only inside the app bundle |
| `uniplayer-plugin/` | Plugin scaffolding tool |
| `OpenInUniPlayer/` | Safari extension for opening a page in UniPlayer |
| `browser/` | Chrome and Firefox extensions |
| `Configs/` | Build configuration and version numbers |
| `scripts/` | Token and extension checks |

The app bundle identifier is `com.lixiaolai.uniplayer`, the URL scheme is
`uniplayer://`, and `plugins.json` continues to list upstream plugins because
the plugin API is unchanged.

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
