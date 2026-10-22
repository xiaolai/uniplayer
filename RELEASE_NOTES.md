# Release notes

## Unreleased

### Inline player

- Playing a local file from the library now happens in the detail column. The
  separate player window no longer opens for normal library playback.
- A minimal auto-hiding control overlay replaces the floating HUD windows:
  play/pause, ±10 seconds, timeline, volume, audio, subtitles, speed and
  fullscreen.
- Double-click the video to enter fullscreen; Escape leaves it. Sidebar and
  inspector hide during fullscreen and return afterwards.
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
