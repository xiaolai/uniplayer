# Contributing

This repository is a fork of [IINA](https://github.com/iina/iina) maintained for
UniPlayer. Upstream's contribution workflow does not apply here; open issues and
pull requests in this repository instead.

## Before you start

- Check the existing issues and pull requests to avoid duplicate work.
- For a large or user-visible change, describe the design first — what it changes,
  what it costs, and how it will be verified.
- Keep unrelated changes out of the same pull request.

## Workflow

1. Build with the instructions in [README.md](README.md#building).
2. Make the change, then run the checks that cover it. At minimum the app must
   build and the test suite must pass; for player or interop changes, exercise
   the affected behaviour in a real session rather than only compiling it.

   ```sh
   python3 scripts/check-design-tokens.py --ledger
   python3 -m unittest scripts/test_check_design_tokens.py
   python3 scripts/validate-browser-extensions.py
   xcodebuild -project uniplayer.xcodeproj -scheme uniplayer \
     -configuration Debug CODE_SIGNING_ALLOWED=NO test
   ```
3. Open one pull request per logical change.

## Presentation model

`PlayerCore` owns the one `VideoView`. `PlayerPresentation` records where that
surface is shown: the player window (`.window`), the mini player (`.miniPlayer`),
or the library detail (`.inline`). `PlayerSurfaceMover` is the only code that
reparents the surface: `attach` for mini and inline hosts, `restore` for the
player window. A new host conforms to `PlayerSurfaceHosting`, owns a container
view, and calls `PlayerCore.presentInline(in:)`; it never constructs a second
player.

Window-only work — the OSC, the HUD, window resizing and `fsState` — is gated on
the presentation. While inline, the player window is loaded but hidden, OSD
messages go to the inline chrome instead of floating panels, and fullscreen
uses a dedicated video-only presentation window. Inline and mini player never hand the surface
directly to each other; the surface returns to the player window first.

## License

By submitting a contribution you agree that it is licensed under GPL-3.0-or-later,
the license of this project.

## Design tokens

Every appearance value is a token in [`uniplayer/DesignTokens.swift`](uniplayer/DesignTokens.swift).
Do not hand-roll a colour, font, spacing, radius, stroke, opacity, size, shadow,
material or animation duration in a view; read the token instead. The values
follow the macOS 27 Human Interface Guidelines: system semantic colours that
adapt to appearance, Increase Contrast and Reduce Transparency; the system
font; Liquid Glass with an opaque visual-effect fallback; and motion that
honours Reduce Motion.

[`DESIGN_TOKENS.md`](DESIGN_TOKENS.md) is the generated ledger. Run
`python3 scripts/check-design-tokens.py --ledger` before opening a pull request;
CI runs the same check. After adding or changing a token, regenerate the ledger
with `python3 scripts/check-design-tokens.py --write-ledger` and commit both
files. Tokens must have a `///` doc comment; the check fails without one.

System text styles (`.font(.body)`, `.font(.caption)`), standard control sizes
and `alphaValue` visibility state are platform semantics rather than design
literals, so they are allowed.

The only escape is a line comment that names a genuinely non-appearance reason,
such as parsing an mpv colour value:

```swift
let color = NSColor(mpvColorString: value) // token-exempt: parses an mpv colour
```

Interface Builder documents must use system catalog colours and `metaFont`s.
Embedded plugin web documents keep their own CSS; they are a separate rendering
surface and are listed under "Coverage" in the ledger.

## Localization

The translations in `uniplayer/*.lproj` come from the upstream project. Do not edit
translations that you did not write; add or change English strings in `Base.lproj`
and `en.lproj`.
