# Release notes

## 0.3.3 (build 29)

- Escape now closes the Settings window. The window had no key handler, so the
  key was swallowed. Field editors still consume it first, so cancelling an
  edit or clearing a focused search field behaves as before.

## 0.3.2 (build 28)

- Cloud-drive channels (preview, off by default): a signed-in Quark or Aliyun
  drive page can resolve a selected video's direct address and play it in the
  native player, with the per-file HTTP headers that address requires.
  Resolution runs only when you choose Play from Drive. Cookies stay in the
  channel's WebKit store and never enter the page script.
- Network playback can carry a user agent, referrer and header fields as
  file-local options, and sensitive option values are redacted from logs.
- The preview needs live-account qualification on real drives before it can be
  relied on. Baidu, 123, UC and Xunlei stay hidden.

## 0.3.1 (build 27)

- Open File now uses a sheet attached to the visible window instead of a
  blocking application-modal panel. On multi-display or full-screen setups the
  old panel could be placed off-screen, leaving the app waiting with no visible
  dialog; the sheet keeps the app responsive and stays with its window.

## 0.3.0 (build 26)

- The AI assistant now receives a richer, explicit context message: media
  identity, playing or paused state, audio and subtitle tracks, the current
  line, a bounded window of recent dialogue, the selection and library
  metadata. Seeks and file changes cannot leave dialogue from a distant scene
  attached to the current one.
- Context-aware presets: What’s happening?, Who is this?, Explain this
  reference, Translate this line, Recap what just happened, Reviews &
  discussion, Is it worth continuing?, and Find similar in library. A preset
  appears only when the context needed to answer it exists.
- Reviews & discussion and Is it worth continuing? use DeepSeek Search with the
  configured DeepSeek key. Results include clickable sources, are bounded
  before they reach the model, and the prompt is spoiler-aware. Search is only
  offered for the HTTPS `api.deepseek.com` origin.
- The assistant can call a `searchWeb` tool. It requires an explicit Allow
  before spending a search, validates the query length, and rechecks the media
  and channel context around every asynchronous step.
- Settings now discloses DeepSeek Search data sharing and billing when that
  capability is available.
- The Simple/Advanced Settings fixes from the previous audit are included:
  hidden pages switch modes correctly, the outgoing mode keeps its remembered
  page, and expanded rows, ASS selections and accessory content survive a
  rebuild.

## 0.2.10 (build 25)

- Settings now has Simple and Advanced modes. Simple keeps the everyday pages:
  General, Interface, Video, Audio, Subtitles, Live Translation and AI
  Assistant. Advanced adds Network, Control, Key Bindings, Plugins, Utilities
  and Advanced, grouped under Playback, Intelligence, Connections and System.
- Advanced-only rows are hidden in Simple mode: Netflix Ratings, the on-screen
  controller and thumbnail sections, Live Text and colour/HDR tuning, and the
  ASS/font/encoding subtitle controls.
- Search still covers every setting. A result hidden in Simple is marked
  Advanced; selecting it switches modes and focuses the row.
- The Settings sidebar has a Simple/Advanced switch, remembers the last page
  per mode, and links to the existing About window.

## 0.2.9 (build 24)

- Stop treating `.js` files as subtitles. A folder containing web assets no
  longer floods the subtitle menu with JavaScript files; `.jss` (JACOSub)
  remains supported.

## 0.2.8 (build 23)

- Torrent downloads a channel starts from a JavaScript button now reach
  Check & Play. M-Team's 下載 control serves an `application/x-bittorrent`
  response from its token endpoint; UniPlayer recognizes the response, reads
  the metainfo in memory, and opens the normal inspection sheet.
- The Open URL loading surface is redesigned around a circular progress gauge
  and a live four-metric grid: torrent name, file and size, connected
  seeds/peers, download speed, selected-file progress and an availability
  verdict while playback waits for pieces.
- The HUD (mini player) shows the torrent source and inspection phase, starts
  playback when the metadata is ready, and reports buffering progress. A
  failed inspection hands the same model to the full Check & Play sheet, and
  a second mini player no longer mirrors another player's status.

## 0.2.7 (build 22)

- Pin the bundled Transmission runtime to 4.1.0. The 4.1.3 runtime is not
  compatible with the channel torrent workflow; 4.1.0 is the same genuine,
  unmodified engine with RPC 6.0.0.

## 0.2.6 (build 21)

- Channels inspect magnet and torrent links and open them in a native sheet
  before playback. The bundled Transmission runtime serves only verified
  pieces; private transfers and resume state are retained.
- Mini4K resource posts offer Check & Play. The torrent preview and the Mini4K
  adapter are enabled by default and remain switchable in Settings › General ›
  Torrent Playback.
- The library toolbar Back and Forward now follow a channel's web history
  while a channel is selected.
- Opening a magnet link from Open URL reaches the torrent inspector instead of
  being rejected as invalid.

## 0.2.5 (build 20)

- AI subtitle translation can now use the reader's signed-in Codex or Claude
  CLI, or Apple's on-device model, in addition to the assistant connection.
  CLI sources run in app-owned folders; live captions use the assistant
  connection or the on-device model because a CLI process is too slow per line.
- OpenAI-compatible assistant settings now offer SaySo service profiles, the
  service's model list, and a one-token connection test.
- The assistant transport applies the profile's auth header, refuses
  cross-origin redirects before replaying a key, and scrubs the key from
  server refusal messages.
- The inspector keeps streaming and typed tool calls; SaySo's one-shot
  provider contract is used where it fits.

## 0.2.4 (build 19)

- Route the library player's pop-out control by media type. Audio opens the
  compact HUD; video opens the standalone player window, with a matching
  out-of-window icon and label.
- The Video menu follows the same rule: audio switches to the HUD, video opens
  the player window, and the item is disabled when a video is already there.
- Leaving the HUD returns to where it was entered: the library inline when it
  came from there, otherwise the player window. A video that reaches the HUD
  now leaves to the visible player window.
- Rename the remaining “Open in New Window” actions to “Open in Player Window”.
  The HUD back control now says “Return to Player”.
- The UniPlayer HUD Finder handler sends audio to the HUD and video to the
  standalone player window.

## 0.2.3 (build 18)

- Group the library's leading toolbar controls into three native groups:
  sidebar toggle, navigation, and open file/URL. Remove the dead Add Source
  toolbar button, which duplicated the File and Sources menus, and the
  duplicate sidebar Search item, which duplicated the toolbar field and ⌘F.
- Add a Switch to HUD Window button to the inline player controls. Rename
  Music Mode to HUD Window across menus, settings, the OSC toolbar and key
  bindings, and correct the HUD media-area toggle label.
- Add the tiny UniPlayer HUD.app Finder handler. Finder's Open With now offers
  both UniPlayer and UniPlayer HUD; the latter opens the selection in the HUD.
  Install both apps; the Homebrew cask must ship both.
- Remove the large Home heading text and its subtitle while preserving the
  heading's line height, so the shelves keep their position.

## 0.2.2 (build 17)

- Restore Netflix IMDb rating badges, which were missing from the release
  branch. Keep the score/vote ribbons, match status, hover previews and saved
  IMDb corrections, using the existing OMDb key in Keychain.
- Restore the Netflix Ratings section in Settings > General for enabling badges
  and managing a personal OMDb key. Credentials stay outside the webpage.
- Check production-channel script registration in tests and require the rating
  script in release packages. Retain the dark appearance, native search and HUD
  alignment fixes from 0.2.1.

## 0.2.1 (build 16)

- Enforce dark appearance across native windows and titlebars, including older
  saved light/system settings. Remove unsupported appearance choices.
- Restore system toolbar search with native sizing and focus. Share the query
  between legacy and media-source search while preserving customized toolbars.
- Align the standalone player's top controls with the native traffic lights,
  balance spacing around them, and center timeline contents. Preserve full-height
  playback behind the transparent titlebar.

## 0.2.0 (build 15)

- Saved local and mounted-share media sources, with folder browsing, indexed
  search, collections, favorites, progress and explicit relinking. Enable the
  preview from the Sources menu; macOS owns share mounting and authentication.
- AI translation for existing text subtitles, plus on-device speech recognition
  and live translation when subtitles are unavailable. Settings exposes language
  packs, audio-capture permission, translation strategy and optional AI repair.
- Media-source and translation features share the existing player and preserve
  catalog resume behavior. Signed runtime, real NAS, audio-permission and
  attended accessibility acceptance remain separate from automated checks.

## 0.1.7 (build 8)

- Developer ID signing, hardened runtime, Apple notarization and stapled tickets
  replace the ad hoc signed distribution used in 0.1.6.
- The release pipeline now verifies Gatekeeper acceptance for the app and DMG
  before producing a distributable package.
- Homebrew users can update with `brew update && brew upgrade --cask uniplayer`.

## 0.1.6 (build 7)

- Full-height video and channel content behind a transparent, draggable native
  titlebar. Playback Back moves into the titlebar; Info moves into transport.
- Individual glass playback buttons without an enclosing panel or background.
- Side panes expand outward while preserving the central viewport. The left
  pane defaults to 280pt; widths are remembered. Panes float when screen space
  cannot accommodate expansion. Central content has a 640pt minimum width.
- Channel navigation is hidden until requested, with an optional floating panel.
- Double-clicking video enters a separate video-only fullscreen presentation;
  Escape, double-click, the fullscreen button or Command-W returns inline.
- Focus mode and ordinary window fullscreen restore the intended pane layout
  when used together.
- Homebrew installation: `brew install --cask xiaolai/tap/uniplayer`.

Validation: 62 native tests and 22 checker tests passed on the review source;
Release build, token/browser/localization checks and live playback/geometry
checks passed on the validation Mac. Intel binaries are built but have not been run
on Intel hardware. Attended accessibility, HDR/DRM and multi-display hardware
acceptance remain outside the tested scope. Builds are ad hoc signed and not
notarized.

## Earlier inline-player and assistant changes

### Inline player

- Playing a local file from the library now happens in the detail column. The
  separate player window no longer opens for normal library playback.
- A minimal auto-hiding control overlay replaces the floating HUD windows:
  play/pause, ±15 seconds, timeline, volume, audio, subtitles, speed and
  fullscreen.
- Double-click the video for video-only fullscreen; Escape returns inline.
  The library window and its panes retain their frame and state.
- `⌘⇧F` toggles a windowed Focus mode that hides both panes without macOS
  fullscreen.
- "Open in New Window" detaches playback to the player window. "Open in
  Library" (`⌘⇧L`) brings it back.
- Navigating away pauses; returning to the item resumes the same position.
  Opening another file replaces it in the same surface.

### AI inspector

- A right inspector (`⌘⌥I`) holds an assistant with explicit context: title,
  timestamp, subtitle line, and the exact text sent.
- Full local file paths are redacted by default and require an opt-in for each
  request.
- Channel pages contribute their title, URL and the current text selection only
  after the user chooses "Use Page as Context".
- Providers: any OpenAI-compatible streaming endpoint (local by default) or the
  Claude Messages API. The API key is stored in the Keychain and never appears
  in defaults or logs.
- Typed tools: seek (requires confirmation), summarize range, translate the
  current subtitle, explain a selection, and find related library items.
  Unknown or malformed tool calls are rejected.

### Known limitations

- Channel DRM playback (Netflix, Amazon) stays in its web view; the inline
  player covers local files.
- The assistant needs a configured endpoint, model and key. Without them the
  inspector shows a clear error and a link to Settings › AI.
- Range summaries have no transcript source; the assistant works from the
  current subtitle line and playback metadata.
