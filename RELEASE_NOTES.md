# Release notes

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
