# Release notes

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
