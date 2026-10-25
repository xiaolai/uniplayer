# Design token ledger

Generated from `uniplayer/DesignTokens.swift` by
`scripts/check-design-tokens.py --write-ledger`. Do not edit by hand.

## The rule

Every appearance value in code is a token. A Swift file may not contain a
raw colour, font, spacing, radius, stroke, opacity, size, shadow, material or
animation duration. Read the token instead; if the value you need does not
exist, add it to `DesignTokens.swift` with a doc comment.

System text styles (`.font(.body)`, `.font(.caption)`), standard control
sizes and `alphaValue` visibility state are platform semantics rather than
design literals, so they are allowed.

`scripts/check-design-tokens.py` enforces the rule in CI. The only escape is
a line comment naming a non-appearance reason:

```swift
let color = NSColor(mpvColorString: value) // token-exempt: parses an mpv colour
```

Values follow the macOS 27 Human Interface Guidelines: system semantic
colours that adapt to appearance, Increase Contrast and Reduce Transparency;
the system font; Liquid Glass with an opaque visual-effect fallback; and
motion that honours Reduce Motion and the app's own animation setting.

## Coverage

| Surface | State |
|---|---|
| AppKit and SwiftUI sources | Checked structurally; every remaining raw value is a finding |
| Interface Builder documents | System catalog colours and `metaFont`s; non-system values require an explicit user-data exception |
| Embedded plugin web documents | Self-contained CSS inside `JavascriptAPIOverlay`, `JavascriptAPIStandaloneWindow`, `PrefPluginViewController` and `SettingsPagePlugin`; a separate rendering surface, not covered by the native ledger |

## Token families

| Family | Purpose |
|---|---|
| `Palette` | Colours: system semantic, product, media, borders, HUD, legacy assets |
| `Typography` | The type ramp, as roles and as a raw size fallback |
| `Space` | Padding, gaps, margins and constraint offsets |
| `Radius` | Corner radii |
| `Stroke` | Line and border widths |
| `Blur` | Shadow and soft-edge blur radii |
| `Opacity` | Alpha values for scrims, borders, tints and disabled states |
| `Size` | Control, component and window dimensions |
| `Icon` | SF Symbol point sizes |
| `Motion` | Durations and curves |
| `Material` | Visual-effect and Liquid Glass configurations |
| `Shadow` | Drop shadows |
| `Aspect` | Media aspect ratios |
| `Library`, `HUD`, `Settings`, `Window` | Component geometry |

## - Tokens

| Token | Declaration | Purpose |
|---|---|---|
| `name` | `static let name: NSAppearance.Name = .darkAqua` | The application and all native window chrome use dark Aqua. |

## Palette · System

| Token | Declaration | Purpose |
|---|---|---|
| `textPrimary` | `static let textPrimary = ColorToken(nsColor: .labelColor)` | The primary text colour. |
| `textSecondary` | `static let textSecondary = ColorToken(nsColor: .secondaryLabelColor)` | Supporting text, such as subtitles and metadata. |
| `textTertiary` | `static let textTertiary = ColorToken(nsColor: .tertiaryLabelColor)` | The least prominent text, such as counts and hints. |
| `textDisabled` | `static let textDisabled = ColorToken(nsColor: .disabledControlTextColor)` | Text on a disabled control. |
| `controlText` | `static let controlText = ColorToken(nsColor: .controlTextColor)` | Text inside an editable control. |
| `documentText` | `static let documentText = ColorToken(nsColor: .textColor)` | Text in a document or text view. |
| `selectedText` | `static let selectedText = ColorToken(nsColor: .selectedTextColor)` | Text under a selection. |
| `accent` | `static let accent = ColorToken(nsColor: .controlAccentColor)` | The user's accent colour. |
| `highlight` | `static let highlight = ColorToken(nsColor: .highlightColor)` | The selection highlight colour. |
| `separator` | `static let separator = ColorToken(nsColor: .separatorColor)` | Hairlines and separators. |
| `grid` | `static let grid = ColorToken(nsColor: .gridColor)` | Table grids. |
| `windowBackground` | `static let windowBackground = ColorToken(nsColor: .windowBackgroundColor)` | A window's backing colour. |
| `controlBackground` | `static let controlBackground = ColorToken(nsColor: .controlBackgroundColor)` | The backing of a control. |
| `destructive` | `static let destructive = ColorToken(nsColor: .systemRed)` | The system's destructive colour. |
| `systemBlue` | `static let systemBlue = ColorToken(nsColor: .systemBlue)` | The system's blue, used by the legacy guide overlay. |
| `systemGreen` | `static let systemGreen = ColorToken(nsColor: .systemGreen)` | The system's green. |
| `systemOrange` | `static let systemOrange = ColorToken(nsColor: .systemOrange)` | The system's orange. |
| `systemBlueHighlight` | `static let systemBlueHighlight = ColorToken(nsColor: .systemBlue.highlight(withLevel: 0.1) ?? .systemBlue)` | The guide overlay's highlighted fill. |
| `currentContrast` | `static var currentContrast: ColorToken { ColorToken(nsColor: NSAppearance.currentDrawing().isDark ? .white : .black) }` | The colour that contrasts with the current drawing appearance. |
| `white` | `static let white = ColorToken(nsColor: .white)` | Opaque white. |
| `black` | `static let black = ColorToken(nsColor: .black)` | Opaque black. |
| `gray` | `static let gray = ColorToken(nsColor: .gray)` | The system's mid grey. |
| `clear` | `static let clear = ColorToken(nsColor: .clear)` | No colour. |

## Palette · Library

| Token | Declaration | Purpose |
|---|---|---|
| `canvas` | `static let canvas = ColorToken.dynamic(light: 0xF2F2F5, dark: 0x0E0E12)` | The page behind the shelves. |
| `sidebar` | `static let sidebar = ColorToken.dynamic(light: 0xE9E9EE, dark: 0x15151A)` | The sidebar and other chrome that sits beside the content. |
| `surface` | `static let surface = ColorToken.dynamic(light: 0xFFFFFF, dark: 0x1C1C22)` | A raised surface: cards, sheets and the search field's backing. |

## Palette · Media

| Token | Declaration | Purpose |
|---|---|---|
| `onMedia` | `static let onMedia = white` | The primary text colour over media. |
| `onMediaSecondary` | `static let onMediaSecondary = white.alpha(0.78)` | Supporting text over media. |
| `onMediaTertiary` | `static let onMediaTertiary = white.alpha(0.72)` | Progress and other secondary detail over media. |
| `onMediaSubtitle` | `static let onMediaSubtitle = white.alpha(0.68)` | A HUD subtitle over media. |
| `onMediaFaint` | `static let onMediaFaint = white.alpha(0.34)` | A decorative glyph over media. |
| `cardShade` | `static let cardShade = black.alpha(0.78)` | The shade that makes text legible at the bottom of a card. |
| `heroShade` | `static let heroShade = black.alpha(0.88)` | The shade that makes text legible at the bottom of a hero. |
| `heroGradientMid` | `static let heroGradientMid = black.alpha(0.18)` | The first stop of the hero gradient. |
| `detailGradientMid` | `static let detailGradientMid = black.alpha(0.15)` | The first stop of the detail gradient. |
| `detailGradientEnd` | `static let detailGradientEnd = black.alpha(0.84)` | The detail page's final gradient stop. |

## Palette · Borders

| Token | Declaration | Purpose |
|---|---|---|
| `mediaBorder` | `static let mediaBorder = white.alpha(0.08)` | A card's resting border over media. |
| `mediaBorderHover` | `static let mediaBorderHover = white.alpha(0.28)` | A card's hover border over media. |
| `mediaBorderHoverStrong` | `static let mediaBorderHoverStrong = white.alpha(0.34)` | A stronger hover border used by the continue-watching card. |
| `mediaBorderIncreased` | `static let mediaBorderIncreased = white.alpha(0.5)` | A border that survives Increase Contrast. |
| `mediaBorderIncreasedStrong` | `static let mediaBorderIncreasedStrong = white.alpha(0.65)` | A stronger border for Increase Contrast. |

## Palette · Player HUD

| Token | Declaration | Purpose |
|---|---|---|
| `hudScrim` | `static let hudScrim = black.alpha(0.30)` | The dark scrim over the video when the HUD is visible. |
| `hudScrimIncreased` | `static let hudScrimIncreased = black.alpha(0.45)` | The scrim used when Increase Contrast is on. |
| `hudTopShade` | `static let hudTopShade = black.alpha(0.62)` | The top gradient behind the utility controls. |
| `hudBottomShade` | `static let hudBottomShade = black.alpha(0.84)` | The bottom gradient behind metadata and the timeline. |
| `hudGlassTint` | `static let hudGlassTint = black.alpha(0.45)` | The tint inside a clear Liquid Glass capsule. |
| `hudDiscGlassTint` | `static let hudDiscGlassTint = black.alpha(0.55)` | The tint inside a regular Liquid Glass transport disc. |
| `hudDiscBackground` | `static let hudDiscBackground = ColorToken(nsColor: NSColor(white: 0.13, alpha: 0.9))` | The opaque backing under a transport disc before glass is applied. |
| `hudControlBorder` | `static let hudControlBorder = white.alpha(0.8)` | A white border on a HUD control. |
| `hudVolumeFill` | `static let hudVolumeFill = white.alpha(0.92)` | The volume slider's played portion inside the HUD. |
| `hudVolumeTrack` | `static let hudVolumeTrack = white.alpha(0.22)` | The volume slider's unplayed portion inside the HUD. |
| `progressTrack` | `static let progressTrack = white.alpha(0.26)` | The track behind a small progress bar over media. |

## Palette · Legacy asset colours

| Token | Declaration | Purpose |
|---|---|---|
| `initialWindowLastFile` | `static let initialWindowLastFile = ColorToken(nsColor: .initialWindowLastFileBackground)` | The initial window's recent-file row. |
| `initialWindowLastFileHover` | `static let initialWindowLastFileHover = ColorToken(nsColor: .initialWindowLastFileBackgroundHover)` | The initial window's recent-file row on hover. |
| `initialWindowLastFilePressed` | `static let initialWindowLastFilePressed = ColorToken(nsColor: .initialWindowLastFileBackgroundPressed)` | The initial window's recent-file row while pressed. |
| `initialWindowBetaLabel` | `static let initialWindowBetaLabel = ColorToken(nsColor: .initialWindowBetaLabel)` | The beta channel label. |
| `initialWindowDebugLabel` | `static let initialWindowDebugLabel = ColorToken(nsColor: .initialWindowDebugLabel)` | The debug channel label. |
| `initialWindowNightlyLabel` | `static let initialWindowNightlyLabel = ColorToken(nsColor: .initialWindowNightlyLabel)` | The nightly channel label. |
| `mainSliderKnob` | `static let mainSliderKnob = ColorToken(nsColor: .mainSliderKnob)` | The main slider's knob. |
| `mainSliderKnobActive` | `static let mainSliderKnobActive = ColorToken(nsColor: .mainSliderKnobActive)` | The main slider's knob while active. |
| `mainSliderBarLeft` | `static let mainSliderBarLeft = ColorToken(nsColor: .mainSliderBarLeft)` | The main slider's played portion. |
| `mainSliderBarRight` | `static let mainSliderBarRight = ColorToken(nsColor: .mainSliderBarRight)` | The main slider's unplayed portion. |
| `mainSliderLoopKnob` | `static let mainSliderLoopKnob = ColorToken(nsColor: .mainSliderLoopKnob)` | The main slider's loop knob. |
| `volumeSliderBarLeft` | `static let volumeSliderBarLeft = ColorToken(nsColor: .volumeSliderBarLeft)` | The volume slider's played portion. |
| `volumeSliderBarRight` | `static let volumeSliderBarRight = ColorToken(nsColor: .volumeSliderBarRight)` | The volume slider's unplayed portion. |
| `sidebarContainerBorder` | `static let sidebarContainerBorder = ColorToken(nsColor: .sidebarContainerBorder)` | The sidebar container border. |
| `sidebarTabButtonBorder` | `static let sidebarTabButtonBorder = ColorToken(nsColor: .sidebarTabBtnBorder)` | The sidebar tab button border. |
| `sidebarTableBackground` | `static let sidebarTableBackground = ColorToken(nsColor: .sidebarTableBackground)` | The sidebar table backing. |
| `sidebarTabTint` | `static let sidebarTabTint = ColorToken(nsColor: .sidebarTabTint)` | An inactive sidebar tab's tint. |
| `sidebarTabTintActive` | `static let sidebarTabTintActive = ColorToken(nsColor: .sidebarTabTintActive)` | The active sidebar tab's tint. |
| `titleBarBorder` | `static let titleBarBorder = ColorToken(nsColor: .titleBarBorder)` | The titlebar's bottom border. |
| `cropBoxFill` | `static let cropBoxFill = ColorToken(nsColor: .cropBoxFill)` | The crop box's fill. |
| `playlistProgressBar` | `static let playlistProgressBar = ColorToken(nsColor: .playlistProgressBar)` | The playlist progress bar. |

## Palette · Legacy computed colours

| Token | Declaration | Purpose |
|---|---|---|
| `keyRecordBackground` | `static let keyRecordBackground = ColorToken(nsColor: .controlBackgroundColor.withSystemEffect(.disabled))` | A key-record view at rest. |
| `keyRecordBackgroundActive` | `static let keyRecordBackgroundActive = ColorToken(nsColor: .controlBackgroundColor)` | An active key-record view. |
| `inspectorWatchBackground` | `static let inspectorWatchBackground = ColorToken(nsColor: NSColor(red: 2.0 / 3, green: 2.0 / 3, blue: 2.0 / 3, alpha: 0.1))` | The inspector watch table's backing. |
| `inspectorWatchHeader` | `static let inspectorWatchHeader = ColorToken(nsColor: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))` | The inspector watch table's column header. |
| `preferenceTabPressed` | `static let preferenceTabPressed = ColorToken(nsColor: .windowBackgroundColor.withSystemEffect(.pressed))` | The pressed background of a preference tab. |
| `aboutGradient` | `static let aboutGradient = ColorToken(nsColor: NSColor(white: 0.925, alpha: 1))` | The app name's gradient base in About. |
| `accentBlend` | `static let accentBlend = ColorToken(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.2, of: .white) ?? .controlAccentColor)` | The accent colour lightened for the playlist selection. |
| `sidebarFillSubtle` | `static let sidebarFillSubtle = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.1))` | A translucent grey used by sidebars and selection pills. |
| `sidebarFill` | `static let sidebarFill = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.15))` | A stronger translucent grey used by sidebars and selection pills. |
| `sidebarFillStrong` | `static let sidebarFillStrong = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.2))` | The strongest translucent grey in the sidebar. |
| `permissionWarningFill` | `static let permissionWarningFill = ColorToken(nsColor: NSColor.systemRed.withAlphaComponent(0.3))` | A red-tinted permission warning box. |
| `sidebarShadow` | `static let sidebarShadow = black.alpha(0.3)` | The legacy shadow under a sidebar tab. |
| `panelShadow` | `static let panelShadow = black.alpha(0.5)` | The legacy shadow under a floating panel. |
| `guideShadow` | `static let guideShadow = black.alpha(0.5)` | The guide overlay's shadow. |
| `shadow` | `static let shadow = black.alpha(0.5)` | The generic black shadow used by legacy AppKit views. |
| `subtitleBorder` | `static let subtitleBorder = black` | The subtitle overlay's border. |
| `subtitleShadow` | `static let subtitleShadow = black` | The subtitle overlay's shadow. |
| `selectedSegmentText` | `static let selectedSegmentText = white` | Text on a selected toolbar segment. |
| `segmentSeparator` | `static let segmentSeparator = white.alpha(0.8)` | The separator inside a segmented control. |
| `inspectorDisabledText` | `static let inspectorDisabledText = textDisabled` | The inspector's disabled row text. |
| `settingsCardBorder` | `static let settingsCardBorder = black.alpha(0.08)` | The settings card's border. |
| `settingsCardBorderSubtle` | `static let settingsCardBorderSubtle = black.alpha(0.05)` | The subtler border used by the settings page container. |
| `settingsCardFill` | `static let settingsCardFill = black.alpha(0.02)` | The settings card's fill. |
| `settingsSelection` | `static let settingsSelection = ColorToken(nsColor: .highlightColor).alpha(0.1)` | A selected settings item. |
| `settingsSelectionStrong` | `static let settingsSelectionStrong = ColorToken(nsColor: .highlightColor).alpha(0.2)` | A strongly selected settings item. |
| `screenshotBorder` | `static let screenshotBorder = ColorToken(nsColor: .gridColor).alpha(0.6)` | The screenshot preview's border. |
| `tableOverlay` | `static let tableOverlay = white.alpha(0.05)` | A faint white overlay on a dark table. |
| `touchBarStroke` | `static let touchBarStroke = ColorToken(nsColor: .labelColor).alpha(0.4)` | A stroke on the Touch Bar preview. |
| `placeholderFill` | `static let placeholderFill = ColorToken(nsColor: .gray).alpha(0.2)` | The placeholder tile behind a missing plugin icon. |
| `logError` | `static let logError = ColorToken(nsColor: .systemRed)` | A log entry at the error level. |
| `logWarning` | `static let logWarning = ColorToken(nsColor: .systemOrange)` | A log entry at the warning level. |
| `logDebug` | `static let logDebug = ColorToken(nsColor: .gray)` | A log entry at the debug or verbose level. |
| `logInfo` | `static let logInfo = ColorToken(nsColor: .systemBlue)` | A log entry at the information level. |
| `logString` | `static let logString = ColorToken(nsColor: .systemBrown)` | A log string value. |
| `logBoolean` | `static let logBoolean = ColorToken(nsColor: .systemPurple)` | A log boolean value. |
| `indicatorNeutral` | `static let indicatorNeutral = ColorToken(nsColor: NSColor(calibratedWhite: 0.5, alpha: 1))` | A neutral indicator glyph. |
| `thumbnailBorder` | `static let thumbnailBorder = ColorToken(nsColor: NSColor(calibratedWhite: 0.6, alpha: 0.5))` | The thumbnail preview's border. |
| `logSuccess` | `static let logSuccess = ColorToken(nsColor: .systemGreen)` | A log entry at the success level. |

## Netflix ratings

| Token | Declaration | Purpose |
|---|---|---|
| `css` | `static let css = """ .uniplayer-imdb-card { position: relative !important; } .uniplayer-imdb-wrap { position: absolute !important; top: 0 !important; right: 0 !important; z-index: 5 !important; display: inline-flex !important; } .uniplayer-imdb-wrap > .uniplayer-imdb-rating { position: relative !important; } .uniplayer-imdb-wrap[data-layout="inline"] { position: relative !important; margin: 8px 0 !important; width: fit-content !important; } .uniplayer-imdb-edit { position: absolute !important; right: 100% !important; top: 0 !important; width: 28px !important; height: 32px !important; padding: 7px !important; border: 0 !important; border-radius: 6px 0 0 6px !important; color: #fff !important; background: #242424 !important; opacity: 0 !important; pointer-events: none !important; cursor: pointer !important; } .uniplayer-imdb-wrap:hover > .uniplayer-imdb-edit, .uniplayer-imdb-wrap:focus-within > .uniplayer-imdb-edit { opacity: 1 !important; pointer-events: auto !important; } .uniplayer-imdb-edit[hidden] { display: none !important; } .uniplayer-imdb-edit svg { width: 100% !important; height: 100% !important; } .uniplayer-imdb-edit:focus-visible { outline: 2px solid #fff !important; outline-offset: 2px !important; } .uniplayer-imdb-rating { position: absolute !important; right: 0 !important; top: 0 !important; bottom: auto !important; left: auto !important; z-index: 5 !important; display: inline-flex !important; align-items: center !important; gap: 7px !important; min-height: 32px !important; min-width: 118px !important; justify-content: center !important; box-sizing: border-box !important; padding: 5px 9px !important; margin: 0 !important; border: 0 !important; border-radius: 0 8px 0 8px !important; background: #e50914 !important; color: #fff !important; font: 700 14px/1.2 -apple-system, BlinkMacSystemFont, sans-serif !important; font-variant-numeric: tabular-nums !important; white-space: nowrap !important; cursor: pointer !important; box-shadow: 0 2px 6px rgba(0,0,0,.28) !important; opacity: 1 !important; text-decoration: none !important; letter-spacing: .1px !important; } .uniplayer-imdb-rating[data-state="unverified"] { background: #301316 !important; box-shadow: inset 0 0 0 1px rgba(255,255,255,.42), 0 2px 6px rgba(0,0,0,.28) !important; } .uniplayer-imdb-rating[data-state="loading"], .uniplayer-imdb-rating[data-state="unavailable"] { min-width: 58px !important; background: #242424 !important; color: #ccc !important; } .uniplayer-imdb-rating .rating-value { font: inherit !important; font-size: 16px !important; } .uniplayer-imdb-rating .rating-votes { font-size: 12px !important; font-weight: 500 !important; } .uniplayer-imdb-rating .rating-status { display: inline-flex !important; width: 15px !important; height: 17px !important; } .uniplayer-imdb-rating .rating-status svg { width: 100% !important; height: 100% !important; } .uniplayer-imdb-rating:focus-visible { outline: 2px solid #fff !important; outline-offset: 2px !important; } """` | Shared badge typography, contrast, placement and focus treatment. |
| `verifiedIcon` | `static let verifiedIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 22" fill="none" aria-hidden="true"><path d="M10 1.5 17.5 4v6.2c0 4.5-3.2 7.6-7.5 10.3-4.3-2.7-7.5-5.8-7.5-10.3V4L10 1.5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="m6.5 10.5 2.4 2.4 4.7-5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>"#` | A confirmed title match, using Netflix release year and format. |
| `editIcon` | `static let editIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="m12.5 3.5 4 4M3 17l4.5-1L17 6.5a2.8 2.8 0 0 0-4-4L3.5 12 3 17Z" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>"#` | Compact correction action, revealed on hover or keyboard focus. |
| `unverifiedIcon` | `static let unverifiedIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 22" fill="none" aria-hidden="true"><path d="M10 1.5 17.5 4v6.2c0 4.5-3.2 7.6-7.5 10.3-4.3-2.7-7.5-5.8-7.5-10.3V4L10 1.5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M7.8 8a2.2 2.2 0 0 1 4.4 0c0 1.8-2.2 1.7-2.2 3.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="10" cy="14.3" r=".9" fill="currentColor"/></svg>"#` | An unconfirmed or unavailable title match, distinct by shape as well as fill. |

## Typography · Library roles

| Token | Declaration | Purpose |
|---|---|---|
| `heroTitle` | `static let heroTitle = FontToken(size: 34, weight: .bold)` | A hero's title. |
| `heroBody` | `static let heroBody = FontToken(size: 15, weight: .regular)` | A hero's supporting line. |
| `sectionTitle` | `static let sectionTitle = FontToken(size: 17, weight: .semibold)` | A page or section heading. |
| `pageTitle` | `static let pageTitle = FontToken(size: 26, weight: .bold)` | A page title above a grid. |
| `channelStateIcon` | `static let channelStateIcon = FontToken(size: 48, weight: .regular)` | Channel identity and connection-state symbol. |
| `cardTitle` | `static let cardTitle = FontToken(size: 13, weight: .semibold)` | A card's title. |
| `titlebarIcon` | `static let titlebarIcon = FontToken(size: 16, weight: .regular)` | A titlebar icon glyph, matching the reference app's toolbar symbols. |
| `body` | `static let body = FontToken(size: NSFont.systemFontSize, weight: .regular)` | Body copy. |
| `button` | `static let button = FontToken(size: NSFont.systemFontSize, weight: .medium)` | A button's label. |
| `bodyStrong` | `static let bodyStrong = FontToken(size: NSFont.systemFontSize, weight: .bold)` | Emphasised body copy. |
| `captionStrong` | `static let captionStrong = FontToken(size: NSFont.smallSystemFontSize, weight: .bold)` | A bold caption. |
| `size12Strong` | `static let size12Strong = FontToken(size: 12, weight: .bold)` | A bold 12 pt label. |
| `menuNumeric` | `static let menuNumeric = FontToken(size: 0, weight: .regular, family: .monospacedDigit)` | The menu's numeric font, sized by the system. |
| `monoTitle` | `static let monoTitle = FontToken(size: 18, weight: .bold, family: .monospaced)` | An 18 pt bold monospaced title. |
| `devBadge` | `static let devBadge = FontToken(size: 10, weight: .bold)` | The small developer badge, which is slightly smaller than a caption. |
| `urlField` | `static let urlField = FontToken(size: 20, weight: .regular)` | The URL field in the Open URL sheet. |
| `loading` | `static let loading = FontToken(size: 16, weight: .regular)` | The loading label in the Open URL sheet. |
| `keyRecord` | `static let keyRecord = FontToken(size: 22, weight: .regular, family: .monospaced)` | The recorded-key display. |
| `codeSample` | `static let codeSample = FontToken(size: 12, weight: .regular, family: .monospaced)` | A code sample shown in settings. |
| `preview` | `static let preview = FontToken(size: 24, weight: .regular)` | The font-picker preview. |
| `systemFont` | `static func systemFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }` | A system font at a dynamic size, for text that scales with user settings. |
| `monoFont` | `static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }` | A monospaced font at a dynamic size. |
| `numericFont` | `static func numericFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }` | A tabular-figure font at a dynamic size. |
| `namedFont` | `static func namedFont(name: String, size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? systemFont(size: size) }` | A font chosen by the user, at a tokenised size. |
| `descriptorFont` | `static func descriptorFont(_ descriptor: NSFontDescriptor, size: CGFloat) -> NSFont { NSFont(descriptor: descriptor, size: size) ?? systemFont(size: size) }` | A font built from a descriptor at a tokenised size. |
| `caption` | `static let caption = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | The smallest supporting line. |
| `searchField` | `static let searchField = FontToken(size: 15, weight: .regular)` | The search field's text. |

## Typography · App roles

| Token | Declaration | Purpose |
|---|---|---|
| `appTitle` | `static let appTitle = FontToken(size: 20, weight: .bold)` | The app name in the initial window. |
| `aboutTitle` | `static let aboutTitle = FontToken(size: 24, weight: .light)` | The app name in About. |
| `detailTitle` | `static let detailTitle = FontToken(size: 18, weight: .regular)` | A dialog or detail title. |
| `detailTitleStrong` | `static let detailTitleStrong = FontToken(size: 18, weight: .semibold)` | An emphasised dialog title. |
| `settingsTitle` | `static let settingsTitle = FontToken(size: 14, weight: .bold)` | A settings page title. |
| `settingsRowTitle` | `static let settingsRowTitle = FontToken(size: 15, weight: .regular)` | A settings row title. |
| `sidebarSection` | `static let sidebarSection = FontToken(size: 12, weight: .bold)` | A sidebar section title. |
| `sidebarItem` | `static let sidebarItem = FontToken(size: 11, weight: .regular)` | A sidebar item label. |
| `sidebarCaption` | `static let sidebarCaption = FontToken(size: 10, weight: .regular)` | A small sidebar label. |
| `badge` | `static let badge = FontToken(size: 10, weight: .regular)` | A tag or badge. |
| `badgeStrong` | `static let badgeStrong = FontToken(size: 10, weight: .bold)` | A small badge. |

## Typography · Numeric and monospaced

| Token | Declaration | Purpose |
|---|---|---|
| `numeric` | `static let numeric = FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospacedDigit)` | Tabular figures for a time or duration. |
| `numericBody` | `static let numericBody = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospacedDigit)` | Tabular figures at body size. |
| `numericTitle` | `static let numericTitle = FontToken(size: 18, weight: .bold, family: .monospacedDigit)` | A bold time display. |
| `mono` | `static let mono = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)` | A monospaced body, for logs and code. |
| `monoCaption` | `static let monoCaption = FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospaced)` | A monospaced caption. |
| `monoKey` | `static let monoKey = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)` | A monospaced key label. |

## Typography · Menu and control variants

| Token | Declaration | Purpose |
|---|---|---|
| `menu` | `static let menu = FontToken(size: 0, weight: .regular, family: .system)` | The system menu font. |
| `message` | `static let message = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | The system message font size. |
| `label` | `static let label = FontToken(size: NSFont.systemFontSize, weight: .regular)` | The system label font size. |

## Typography · Raw ramp

| Token | Declaration | Purpose |
|---|---|---|
| `size9` | `static let size9 = FontToken(size: 10, weight: .regular)` | 9 pt, for the smallest labels that predate the role ramp. |
| `size10` | `static let size10 = FontToken(size: 10, weight: .regular)` | 10 pt supporting text. |
| `size11` | `static let size11 = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | 11 pt system text. |
| `size12` | `static let size12 = FontToken(size: 12, weight: .regular)` | 12 pt text. |
| `size13` | `static let size13 = body` | 13 pt system text. |
| `size13_5` | `static let size13_5 = FontToken(size: 13.5, weight: .regular)` | 13.5 pt, used by toolbar symbols. |
| `size14` | `static let size14 = FontToken(size: 14, weight: .regular)` | 14 pt text. |
| `size15` | `static let size15 = searchField` | 15 pt text. |
| `size16` | `static let size16 = FontToken(size: 16, weight: .regular)` | 16 pt text. |
| `size18` | `static let size18 = detailTitle` | 18 pt text. |
| `size20` | `static let size20 = FontToken(size: 20, weight: .regular)` | 20 pt text. |
| `size24` | `static let size24 = aboutTitle` | 24 pt text. |
| `size26` | `static let size26 = pageTitle` | 26 pt text. |
| `size30` | `static let size30 = FontToken(size: 30, weight: .regular)` | 30 pt text. |
| `size34` | `static let size34 = heroTitle` | 34 pt text. |
| `size42` | `static let size42 = FontToken(size: 42, weight: .light)` | 42 pt text. |

## Spacing

| Token | Declaration | Purpose |
|---|---|---|
| `sheetWidth` | `static let sheetWidth: CGFloat = 600` | Spacing and inset values. The numeric names are the scale; the named aliases give the recurring roles a meaning. Torrent action and native inspection surface; isolated from window chrome. |
| `sheetHeight` | `static let sheetHeight: CGFloat = 620` | Spacing and inset values. The numeric names are the scale; the named aliases give the recurring roles a meaning. Torrent action and native inspection surface; isolated from window chrome. |
| `icon` | `static let icon = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' aria-hidden='true'><path d='M9 6v12l10-6z' fill='currentColor'/><path d='M6 4H3v16h3' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round'/></svg>"` | Spacing and inset values. The numeric names are the scale; the named aliases give the recurring roles a meaning. Torrent action and native inspection surface; isolated from window chrome. |
| `css` | `static let css = """ .uniplayer-torrent-action {display:inline-flex!important;align-items:center!important;justify-content:center!important;vertical-align:middle!important;width:32px!important;height:32px!important;margin:4px 6px!important;border:1px solid #ffffff30!important;border-radius:9px!important;background:#24262cf5!important;color:#f4c65c!important;cursor:pointer!important;box-shadow:0 2px 6px #0005!important;line-height:1!important;padding:5px!important;} .uniplayer-torrent-action:hover {background:#3b3d44!important;color:#ffe19b!important;} .uniplayer-torrent-action:focus-visible {outline:3px solid #71aaff!important;outline-offset:2px!important;} .uniplayer-torrent-action svg {width:20px!important;height:20px!important;pointer-events:none!important;} """` | Spacing and inset values. The numeric names are the scale; the named aliases give the recurring roles a meaning. Torrent action and native inspection surface; isolated from window chrome. |
| `n0` | `static let n0: CGFloat = 0` | 0 pt. |
| `n1` | `static let n1: CGFloat = 1` | 1 pt. |
| `n2` | `static let n2: CGFloat = 2` | 2 pt. |
| `n2_5` | `static let n2_5: CGFloat = 2.5` | 2.5 pt. |
| `n3` | `static let n3: CGFloat = 3` | 3 pt. |
| `n4` | `static let n4: CGFloat = 4` | 4 pt. |
| `n5` | `static let n5: CGFloat = 5` | 5 pt. |
| `n6` | `static let n6: CGFloat = 6` | 6 pt. |
| `n8` | `static let n8: CGFloat = 8` | 8 pt. |
| `n9` | `static let n9: CGFloat = 9` | 9 pt. |
| `n10` | `static let n10: CGFloat = 10` | 10 pt. |
| `n11` | `static let n11: CGFloat = 11` | 11 pt. |
| `n12` | `static let n12: CGFloat = 12` | 12 pt. |
| `n14` | `static let n14: CGFloat = 14` | 14 pt. |
| `n15` | `static let n15: CGFloat = 15` | 15 pt. |
| `n16` | `static let n16: CGFloat = 16` | 16 pt. |
| `n17` | `static let n17: CGFloat = 17` | 17 pt. |
| `n18` | `static let n18: CGFloat = 18` | 18 pt. |
| `n19` | `static let n19: CGFloat = 19` | 19 pt. |
| `n20` | `static let n20: CGFloat = 20` | 20 pt. |
| `n24` | `static let n24: CGFloat = 24` | 24 pt. |
| `n25` | `static let n25: CGFloat = 25` | 25 pt. |
| `n26` | `static let n26: CGFloat = 26` | 26 pt. |
| `n28` | `static let n28: CGFloat = 28` | 28 pt. |
| `n30` | `static let n30: CGFloat = 30` | 30 pt. |
| `n32` | `static let n32: CGFloat = 32` | 32 pt. |
| `n36` | `static let n36: CGFloat = 36` | 36 pt. |
| `n45` | `static let n45: CGFloat = 45` | 45 pt. |
| `n46` | `static let n46: CGFloat = 46` | 46 pt. |
| `n40` | `static let n40: CGFloat = 40` | 40 pt. |
| `n48` | `static let n48: CGFloat = 48` | 48 pt. |
| `n52` | `static let n52: CGFloat = 52` | 52 pt. |
| `n60` | `static let n60: CGFloat = 60` | 60 pt. |
| `n64` | `static let n64: CGFloat = 64` | 64 pt. |
| `n68` | `static let n68: CGFloat = 68` | 68 pt. |
| `n80` | `static let n80: CGFloat = 80` | 80 pt. |
| `n84` | `static let n84: CGFloat = 84` | 84 pt. |
| `n86` | `static let n86: CGFloat = 86` | 86 pt, the titlebar's leading inset that clears the traffic lights. |
| `n200` | `static let n200: CGFloat = 200` | 200 pt. |
| `n260` | `static let n260: CGFloat = 260` | 260 pt. |
| `n300` | `static let n300: CGFloat = 300` | 300 pt. |

## Spacing · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `controlGap` | `static let controlGap = n8` | The gap between related controls. |
| `rowGap` | `static let rowGap = n12` | The gap between rows in a stack. |
| `titleGap` | `static let titleGap = n12` | The gap between a title and its shelf. |
| `sectionGap` | `static let sectionGap = n32` | The gap between sections. |
| `pageMargin` | `static let pageMargin = n40` | The page's horizontal margin. |
| `pageTop` | `static let pageTop = n24` | The page's top margin. |
| `pageBottom` | `static let pageBottom = n48` | The page's bottom margin. |

## Radius

| Token | Declaration | Purpose |
|---|---|---|
| `n0` | `static let n0: CGFloat = 0` | 0 pt. |
| `n1` | `static let n1: CGFloat = 1` | 1 pt. |
| `n1_5` | `static let n1_5: CGFloat = 1.5` | 1.5 pt. |
| `n2` | `static let n2: CGFloat = 2` | 2 pt. |
| `n2_5` | `static let n2_5: CGFloat = 2.5` | 2.5 pt. |
| `n3` | `static let n3: CGFloat = 3` | 3 pt. |
| `n4` | `static let n4: CGFloat = 4` | 4 pt. |
| `n6` | `static let n6: CGFloat = 6` | 6 pt. |
| `n8` | `static let n8: CGFloat = 8` | 8 pt. |
| `n10` | `static let n10: CGFloat = 10` | 10 pt. |
| `n11` | `static let n11: CGFloat = 11` | 11 pt. |
| `n12` | `static let n12: CGFloat = 12` | 12 pt. |
| `n14` | `static let n14: CGFloat = 14` | 14 pt. |
| `n15` | `static let n15: CGFloat = 15` | 15 pt. |
| `n16` | `static let n16: CGFloat = 16` | 16 pt. |
| `n18` | `static let n18: CGFloat = 18` | 18 pt. |

## Radius · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `card` | `static let card = n10` | A card's corner. |
| `hero` | `static let hero = n14` | A hero's corner. |
| `capsule` | `static let capsule = n15` | A HUD capsule's corner. |
| `timeline` | `static let timeline = n14` | The HUD timeline's corner. |
| `settingsCard` | `static let settingsCard = n12` | A settings card's corner, which follows the platform's control shape. |
| `control` | `static let control = n4` | A small control's corner. |
| `sidebarContainer` | `static let sidebarContainer = n8` | A sidebar container's corner. |
| `panel` | `static let panel = n10` | A floating panel's corner. |

## Stroke

| Token | Declaration | Purpose |
|---|---|---|
| `none` | `static let none: CGFloat = 0` | No stroke. |
| `hairline` | `static let hairline: CGFloat = 1` | A hairline. |
| `n0_4` | `static let n0_4: CGFloat = 0.4` | 0.4 pt, the legacy slider outline. |
| `n1_5` | `static let n1_5: CGFloat = 1.5` | 1.5 pt. |
| `n4` | `static let n4: CGFloat = 4` | 4 pt. |
| `strong` | `static let strong: CGFloat = 2` | A prominent border. |
| `focus` | `static let focus: CGFloat = 3` | A focus ring. |

## Blur

| Token | Declaration | Purpose |
|---|---|---|
| `n1` | `static let n1: CGFloat = 1` | 1 pt. |
| `n2` | `static let n2: CGFloat = 2` | 2 pt. |
| `n4` | `static let n4: CGFloat = 4` | 4 pt. |
| `n6` | `static let n6: CGFloat = 6` | 6 pt. |
| `n8` | `static let n8: CGFloat = 8` | 8 pt. |
| `n10` | `static let n10: CGFloat = 10` | 10 pt. |
| `n12` | `static let n12: CGFloat = 12` | 12 pt. |
| `n13` | `static let n13: CGFloat = 13` | 13 pt. |
| `n14` | `static let n14: CGFloat = 14` | 14 pt. |
| `n24` | `static let n24: CGFloat = 24` | 24 pt. |

## Opacity

| Token | Declaration | Purpose |
|---|---|---|
| `n00` | `static let n00: CGFloat = 0` | 0. |
| `n02` | `static let n02: CGFloat = 0.02` | 0.02. |
| `n05` | `static let n05: CGFloat = 0.05` | 0.05. |
| `n08` | `static let n08: CGFloat = 0.08` | 0.08. |
| `n10` | `static let n10: CGFloat = 0.10` | 0.10. |
| `n12` | `static let n12: CGFloat = 0.12` | 0.12. |
| `n15` | `static let n15: CGFloat = 0.15` | 0.15. |
| `n18` | `static let n18: CGFloat = 0.18` | 0.18. |
| `n20` | `static let n20: CGFloat = 0.20` | 0.20. |
| `n22` | `static let n22: CGFloat = 0.22` | 0.22. |
| `n26` | `static let n26: CGFloat = 0.26` | 0.26. |
| `n28` | `static let n28: CGFloat = 0.28` | 0.28. |
| `n30` | `static let n30: CGFloat = 0.30` | 0.30. |
| `n34` | `static let n34: CGFloat = 0.34` | 0.34. |
| `n35` | `static let n35: CGFloat = 0.35` | 0.35. |
| `n40` | `static let n40: CGFloat = 0.40` | 0.40. |
| `n45` | `static let n45: CGFloat = 0.45` | 0.45. |
| `n50` | `static let n50: CGFloat = 0.50` | 0.50. |
| `n55` | `static let n55: CGFloat = 0.55` | 0.55. |
| `n60` | `static let n60: CGFloat = 0.60` | 0.60. |
| `n62` | `static let n62: CGFloat = 0.62` | 0.62. |
| `n65` | `static let n65: CGFloat = 0.65` | 0.65. |
| `n68` | `static let n68: CGFloat = 0.68` | 0.68. |
| `n72` | `static let n72: CGFloat = 0.72` | 0.72. |
| `n78` | `static let n78: CGFloat = 0.78` | 0.78. |
| `n80` | `static let n80: CGFloat = 0.80` | 0.80. |
| `n84` | `static let n84: CGFloat = 0.84` | 0.84. |
| `n88` | `static let n88: CGFloat = 0.88` | 0.88. |
| `n90` | `static let n90: CGFloat = 0.90` | 0.90. |
| `n92` | `static let n92: CGFloat = 0.92` | 0.92. |
| `n96` | `static let n96: CGFloat = 0.96` | 0.96. |
| `n98` | `static let n98: CGFloat = 0.98` | 0.98. |
| `opaque` | `static let opaque: CGFloat = 1` | Fully visible content. |
| `disabled` | `static let disabled = n40` | A disabled control's opacity. |
| `border` | `static let border = n08` | A resting border. |
| `borderHover` | `static let borderHover = n28` | A hover border. |
| `scrim` | `static let scrim = n30` | The HUD's scrim. |

## Sizes

| Token | Declaration | Purpose |
|---|---|---|
| `n0` | `static let n0: CGFloat = 0` | 0 pt. |
| `n1` | `static let n1: CGFloat = 1` | 1 pt. |
| `n3` | `static let n3: CGFloat = 3` | 3 pt. |
| `n0_75` | `static let n0_75: CGFloat = 0.75` | 0.75 pt. |
| `n10` | `static let n10: CGFloat = 10` | 10 pt. |
| `n11` | `static let n11: CGFloat = 11` | 11 pt. |
| `n12` | `static let n12: CGFloat = 12` | 12 pt. |
| `n13` | `static let n13: CGFloat = 13` | 13 pt. |
| `n14` | `static let n14: CGFloat = 14` | 14 pt. |
| `n24` | `static let n24: CGFloat = 24` | 24 pt. |
| `n25` | `static let n25: CGFloat = 25` | 25 pt. |
| `n2_5` | `static let n2_5: CGFloat = 2.5` | 25 pt. |
| `n26` | `static let n26: CGFloat = 26` | 26 pt. |
| `n28` | `static let n28: CGFloat = 28` | 28 pt. |
| `n30` | `static let n30: CGFloat = 30` | 30 pt. |
| `n31` | `static let n31: CGFloat = 31` | 31 pt. |
| `n36` | `static let n36: CGFloat = 36` | 36 pt. |
| `n37` | `static let n37: CGFloat = 37` | 37 pt. |
| `n42` | `static let n42: CGFloat = 42` | 42 pt. |
| `n48` | `static let n48: CGFloat = 48` | 48 pt. |
| `n52` | `static let n52: CGFloat = 52` | 52 pt. |
| `n50` | `static let n50: CGFloat = 50` | 50 pt. |
| `n60` | `static let n60: CGFloat = 60` | 60 pt. |
| `n64` | `static let n64: CGFloat = 64` | 64 pt. |
| `n120` | `static let n120: CGFloat = 120` | 120 pt. |
| `n200` | `static let n200: CGFloat = 200` | 200 pt. |
| `n285` | `static let n285: CGFloat = 285` | 285 pt. |
| `n300` | `static let n300: CGFloat = 300` | 300 pt. |
| `n400` | `static let n400: CGFloat = 400` | 400 pt. |
| `n480` | `static let n480: CGFloat = 480` | 480 pt. |
| `n500` | `static let n500: CGFloat = 500` | 500 pt. |
| `n600` | `static let n600: CGFloat = 600` | 600 pt. |
| `n640` | `static let n640: CGFloat = 640` | 640 pt. |
| `n800` | `static let n800: CGFloat = 800` | 800 pt. |
| `n2000` | `static let n2000: CGFloat = 2000` | 2000 pt. |
| `n0_5` | `static let n0_5: CGFloat = 0.5` | 0.5 pt. |
| `n67` | `static let n67: CGFloat = 67` | 67 pt. |
| `n96` | `static let n96: CGFloat = 96` | 96 pt. |
| `n100` | `static let n100: CGFloat = 100` | 100 pt. |
| `n140` | `static let n140: CGFloat = 140` | 140 pt. |
| `n146` | `static let n146: CGFloat = 146` | 146 pt. |
| `n180` | `static let n180: CGFloat = 180` | 180 pt. |
| `n220` | `static let n220: CGFloat = 220` | 220 pt. |
| `n240` | `static let n240: CGFloat = 240` | 240 pt. |
| `n260` | `static let n260: CGFloat = 260` | 260 pt. |
| `n340` | `static let n340: CGFloat = 340` | 340 pt. |
| `n360` | `static let n360: CGFloat = 360` | 360 pt. |
| `n420` | `static let n420: CGFloat = 420` | 420 pt. |
| `n430` | `static let n430: CGFloat = 430` | 430 pt. |
| `n2` | `static let n2: CGFloat = 2` | 2 pt. |
| `n4` | `static let n4: CGFloat = 4` | 4 pt. |
| `n8` | `static let n8: CGFloat = 8` | 8 pt. |
| `n15` | `static let n15: CGFloat = 15` | 15 pt. |
| `n16` | `static let n16: CGFloat = 16` | 16 pt. |
| `n17` | `static let n17: CGFloat = 17` | 17 pt. |
| `n18` | `static let n18: CGFloat = 18` | 18 pt. |
| `n19` | `static let n19: CGFloat = 19` | 19 pt. |
| `n20` | `static let n20: CGFloat = 20` | 20 pt. |
| `n22` | `static let n22: CGFloat = 22` | 22 pt. |
| `n32` | `static let n32: CGFloat = 32` | 32 pt. |
| `n45` | `static let n45: CGFloat = 45` | 45 pt. |
| `n46` | `static let n46: CGFloat = 46` | 46 pt. |
| `n40` | `static let n40: CGFloat = 40` | 40 pt. |
| `n70` | `static let n70: CGFloat = 70` | 70 pt. |
| `n80` | `static let n80: CGFloat = 80` | 80 pt. |
| `n105_6` | `static let n105_6: CGFloat = 105.6` | 105.6 pt. |
| `n108` | `static let n108: CGFloat = 108` | 108 pt. |
| `n150` | `static let n150: CGFloat = 150` | 150 pt. |
| `n59_4` | `static let n59_4: CGFloat = 59.4` | 59.4 pt. |
| `n440` | `static let n440: CGFloat = 440` | 440 pt. |
| `n450` | `static let n450: CGFloat = 450` | 450 pt. |
| `n520` | `static let n520: CGFloat = 520` | 520 pt. |
| `n560` | `static let n560: CGFloat = 560` | 560 pt. |
| `n54` | `static let n54: CGFloat = 54` | 54 pt. |
| `n82` | `static let n82: CGFloat = 82` | 82 pt. |
| `n90` | `static let n90: CGFloat = 90` | 90 pt. |
| `n98` | `static let n98: CGFloat = 98` | 98 pt. |
| `n68` | `static let n68: CGFloat = 68` | 68 pt. |

## Sizes · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `window` | `static let window = NSSize(width: 1220, height: 720)` | The library window's default size. |
| `minimumWindow` | `static let minimumWindow = NSSize(width: 900, height: 560)` | The library window's minimum size. |
| `sidebarWidth` | `static let sidebarWidth: CGFloat = 220` | The library sidebar's ideal width. |
| `titlebarHeight` | `static let titlebarHeight: CGFloat = 32` | The titlebar's height. |
| `settingsSidebarWidth` | `static let settingsSidebarWidth: CGFloat = 180` | The settings sidebar's width. |
| `settingsContentWidth` | `static let settingsContentWidth: CGFloat = 340` | The settings content's width. |
| `settingsWindowWidth` | `static let settingsWindowWidth: CGFloat = 650` | The settings window's width. |
| `inputWidth` | `static let inputWidth: CGFloat = 48` | A numeric input's width. |
| `inputHeight` | `static let inputHeight: CGFloat = 25` | A numeric input's height. |
| `textInputWidth` | `static let textInputWidth: CGFloat = 64` | A text input's width. |
| `colorWellHeight` | `static let colorWellHeight: CGFloat = 24` | A colour well's height. |
| `colorWellWidth` | `static let colorWellWidth: CGFloat = 30` | A colour well's fallback width. |
| `cardWidth` | `static let cardWidth: CGFloat = 215` | The library card's width. |
| `cardHeight` | `static let cardHeight: CGFloat = 151` | The library card's height. |
| `gridMinimum` | `static let gridMinimum: CGFloat = 200` | The minimum adaptive grid item. |
| `gridMaximum` | `static let gridMaximum: CGFloat = 280` | The maximum adaptive grid item. |
| `searchFieldWidth` | `static let searchFieldWidth: CGFloat = 420` | The library search field's width. |
| `oscFloatingWidth` | `static let oscFloatingWidth: CGFloat = 460` | The floating OSC's width. |
| `imagePreviewWidth` | `static let imagePreviewWidth: CGFloat = 480 * 0.22` | The settings screenshot preview's width. |
| `imagePreviewHeight` | `static let imagePreviewHeight: CGFloat = 270 * 0.22` | The settings screenshot preview's height. |
| `progressWidth` | `static let progressWidth: CGFloat = 180` | The detail page's progress width. |
| `emptyStateWidth` | `static let emptyStateWidth: CGFloat = 360` | The empty state's message width. |

## Icons

| Token | Declaration | Purpose |
|---|---|---|
| `n10` | `static let n10: CGFloat = 10` | 10 pt. |
| `n11` | `static let n11: CGFloat = 11` | 11 pt. |
| `n12` | `static let n12: CGFloat = 12` | 12 pt. |
| `n13` | `static let n13: CGFloat = 13` | 13 pt. |
| `n13_5` | `static let n13_5: CGFloat = 13.5` | 13.5 pt. |
| `n14` | `static let n14: CGFloat = 14` | 14 pt. |
| `n15` | `static let n15: CGFloat = 15` | 15 pt. |
| `n16` | `static let n16: CGFloat = 16` | 16 pt. |
| `n17` | `static let n17: CGFloat = 17` | 17 pt. |
| `n18` | `static let n18: CGFloat = 18` | 18 pt. |
| `n19` | `static let n19: CGFloat = 19` | 19 pt. |
| `n20` | `static let n20: CGFloat = 20` | 20 pt. |
| `n24` | `static let n24: CGFloat = 24` | 24 pt. |
| `n25` | `static let n25: CGFloat = 25` | 25 pt. |
| `n2_5` | `static let n2_5: CGFloat = 2.5` | 25 pt. |
| `n26` | `static let n26: CGFloat = 26` | 26 pt. |
| `n28` | `static let n28: CGFloat = 28` | 28 pt. |
| `n30` | `static let n30: CGFloat = 30` | 30 pt. |
| `n34` | `static let n34: CGFloat = 34` | 34 pt. |
| `n42` | `static let n42: CGFloat = 42` | 42 pt. |
| `n68` | `static let n68: CGFloat = 68` | 68 pt. |

## Motion

| Token | Declaration | Purpose |
|---|---|---|
| `none` | `static let none = MotionToken(duration: 0)` | No animation. |
| `n10` | `static let n10 = MotionToken(duration: 0.1, curve: .easeOut)` | 0.1 seconds. |
| `hover` | `static let hover = MotionToken(duration: 0.16, curve: .easeOut)` | 0.16 seconds; the library's hover and focus motion. |
| `n20` | `static let n20 = MotionToken(duration: 0.2, curve: .easeOut)` | 0.2 seconds. |
| `n24` | `static let n24 = MotionToken(duration: 0.24, curve: .easeIn)` | 0.24 seconds. |
| `n25` | `static let n25 = MotionToken(duration: 0.25, curve: .easeInOut)` | 0.25 seconds. |
| `n30` | `static let n30 = MotionToken(duration: 0.3, curve: .easeOut)` | 0.3 seconds. |
| `n50` | `static let n50 = MotionToken(duration: 0.5, curve: .easeOut)` | 0.5 seconds. |
| `caretBlink` | `static let caretBlink: TimeInterval = 1.0` | The caret blink interval. |
| `pulse` | `static let pulse: TimeInterval = 1.5` | The slowest repeating UI pulse. |
| `window` | `static let window = n25` | The standard window-resize animation. |
| `swiftUI` | `static func swiftUI(_ token: MotionToken, reduceMotion: Bool) -> Animation? { if reduceMotion \|\| Preference.bool(for: .disableAnimations) { return nil } return token.animation }` | The SwiftUI animation for a token, honouring both Reduce Motion and the app's own animation preference. |
| `hud` | `static let hud = n25` | The standard HUD fade. |
| `sidebar` | `static let sidebar = n24` | The standard sidebar transition. |
| `settings` | `static let settings = n25` | The standard settings transition. |

## Materials

| Token | Declaration | Purpose |
|---|---|---|
| `popover` | `static let popover = VisualEffect(material: .popover, blending: .withinWindow, state: .active)` | A popover-style within-window material. |
| `sidebar` | `static let sidebar = VisualEffect(material: .sidebar, blending: .withinWindow, state: .active)` | A sidebar material. |
| `librarySidebar` | `static let librarySidebar = VisualEffect(material: .sidebar, blending: .behindWindow, state: .followsWindowActiveState)` | Library sidebar vibrancy, tracking the window's active state. |
| `titlebar` | `static let titlebar = VisualEffect(material: .titlebar, blending: .withinWindow, state: .active)` | A titlebar material. |
| `underWindowBackground` | `static let underWindowBackground = VisualEffect(material: .underWindowBackground, blending: .behindWindow, state: .active)` | A window-background material behind the content. |
| `windowBackground` | `static let windowBackground = VisualEffect(material: .windowBackground, blending: .withinWindow, state: .active)` | A window-background material for footers. |
| `glassCapsule` | `static let glassCapsule = Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)` | The clear Liquid Glass group used by the HUD's utility capsules. |
| `glassTransport` | `static let glassTransport = Glass(style: .regular, tint: Palette.hudDiscGlassTint, interactive: false)` | The regular Liquid Glass transport disc. |
| `glassTimeline` | `static let glassTimeline = Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)` | The clear Liquid Glass timeline capsule. |
| `glassFallback` | `static let glassFallback = VisualEffect(material: .popover, blending: .withinWindow, state: .active)` | The opaque fallback used when Liquid Glass is unavailable. |

## Shadows

| Token | Declaration | Purpose |
|---|---|---|
| `card` | `static let card = ShadowToken(color: Palette.black.alpha(Opacity.n22), radius: Blur.n12, offset: CGSize(width: 0, height: 5))` | A card's resting shadow. |
| `cardHover` | `static let cardHover = ShadowToken(color: Palette.black.alpha(Opacity.n28), radius: Blur.n14, offset: CGSize(width: 0, height: 6))` | A card's hover shadow. |
| `hero` | `static let hero = ShadowToken(color: Palette.black.alpha(Opacity.n35), radius: Blur.n24, offset: CGSize(width: 0, height: 12))` | A hero's shadow. |
| `icon` | `static let icon = ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Blur.n2, offset: CGSize(width: 0, height: 1))` | A small icon shadow. |
| `panel` | `static let panel = ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Blur.n4, offset: CGSize(width: 0, height: 0))` | A floating panel's shadow. |
| `titlebarText` | `static let titlebarText = ShadowToken(color: Palette.black, radius: Blur.n2, offset: .zero)` | The titlebar text's shadow. |

## Library

| Token | Declaration | Purpose |
|---|---|---|
| `contentMinimumWidth` | `static let contentMinimumWidth: CGFloat = 640` | Minimum width of the central video or webpage, excluding docked panes. |
| `outwardSidebarWidth` | `static let outwardSidebarWidth: CGFloat = 280` | Initial width of the outward-opening library sidebar. |
| `outwardSidebarMinimum` | `static let outwardSidebarMinimum: CGFloat = 240` | Smallest remembered outward sidebar width. |
| `outwardSidebarMaximum` | `static let outwardSidebarMaximum: CGFloat = 420` | Largest remembered outward sidebar width. |
| `titlebarHeight` | `static let titlebarHeight: CGFloat = 52` | Transparent top strip reserved for window dragging and titlebar controls. |
| `channelStateMaximumWidth` | `static let channelStateMaximumWidth: CGFloat = 420` | Readable width of the channel connection and recovery state. |
| `mediaOverlayColorScheme` | `static let mediaOverlayColorScheme: ColorScheme = .dark` | Media overlays use dark control rendering against the video surface. |
| `transportMaximumWidth` | `static let transportMaximumWidth: CGFloat = 720` | Maximum width of floating playback transport. |
| `glassControlSize` | `static let glassControlSize: CGFloat = 36` | Individual glass playback button diameter. |
| `paneResizeWidth` | `static let paneResizeWidth: CGFloat = 8` | Draggable pane separator hit width. |
| `playControlSize` | `static let playControlSize: CGFloat = 44` | Diameter of the inline player's primary transport control. |
| `heroMaximumHeight` | `static let heroMaximumHeight: CGFloat = 280` | Maximum height of the Home overview artwork. |
| `playerReservedHeight` | `static let playerReservedHeight: CGFloat = 240` | The space reserved around a viewport-bounded player. |
| `playerMinimumHeight` | `static let playerMinimumHeight: CGFloat = 150` | Minimum useful inline media height. |
| `detailMinimumWidth` | `static let detailMinimumWidth: CGFloat = 520` | Minimum detail width before hiding the sidebar beside an inspector. |
| `inspectorCollapseWidth` | `static let inspectorCollapseWidth: CGFloat = 1160` | Width at which the inspector needs the sidebar space. |
| `listThumbnailHeight` | `static let listThumbnailHeight: CGFloat = 48` | Height of the compact list thumbnail. |
| `listThumbnailWidth` | `static let listThumbnailWidth: CGFloat = 84` | Width of the compact list thumbnail. |
| `transportBacking` | `static let transportBacking = ColorToken(nsColor: NSColor(white: 0.10, alpha: 1))` | Opaque media control backing for stable contrast. |
| `cardSpacing` | `static let cardSpacing: CGFloat = Space.n8` | The vertical gap inside a card. |
| `cardPadding` | `static let cardPadding: CGFloat = Space.n12` | The padding inside a card. |
| `cardGap` | `static let cardGap: CGFloat = Space.n20` | The gap between cards. |
| `shelfSpacing` | `static let shelfSpacing: CGFloat = Space.n12` | The gap inside a shelf. |
| `shelfHeaderSpacing` | `static let shelfHeaderSpacing: CGFloat = Space.n12` | The gap between a shelf's title and its content. |
| `heroSpacing` | `static let heroSpacing: CGFloat = Space.n10` | The gap inside the hero's text block. |
| `heroPadding` | `static let heroPadding: CGFloat = Space.n32` | The hero's inner padding. |
| `heroButtonHorizontal` | `static let heroButtonHorizontal: CGFloat = Space.n18` | The hero button's horizontal padding. |
| `heroButtonVertical` | `static let heroButtonVertical: CGFloat = Space.n9` | The hero button's vertical padding. |
| `focusRingOutset` | `static let focusRingOutset: CGFloat = Space.n3` | The focus ring's outset. |
| `gridRowGap` | `static let gridRowGap: CGFloat = Space.n24` | The grid's row gap. |
| `sidebarMinimum` | `static let sidebarMinimum: CGFloat = Size.n200` | The sidebar's minimum width. |
| `sidebarMaximum` | `static let sidebarMaximum: CGFloat = Size.n260` | The sidebar's maximum width. |
| `sidebarVersionInset` | `static let sidebarVersionInset: CGFloat = Space.n16` | The sidebar version label's inset. |
| `sidebarVersionBottom` | `static let sidebarVersionBottom: CGFloat = Space.n10` | The sidebar version label's bottom inset. |
| `emptyStateMinimum` | `static let emptyStateMinimum: CGFloat = Size.n260` | The empty state's minimum height. |
| `gridEmptyStateMinimum` | `static let gridEmptyStateMinimum: CGFloat = Size.n300` | The grid page's empty state minimum height. |
| `searchCorner` | `static let searchCorner = Radius.n10` | The search field's corner. |
| `searchHorizontal` | `static let searchHorizontal: CGFloat = Space.n14` | The search field's horizontal padding. |
| `searchVertical` | `static let searchVertical: CGFloat = Space.n10` | The search field's vertical padding. |
| `searchTop` | `static let searchTop: CGFloat = Space.n32` | The search field's top margin. |
| `dropCorner` | `static let dropCorner = Radius.n18` | The drop overlay's corner. |
| `dropDash` | `static let dropDash: [CGFloat] = [Space.n8, Space.n6]` | The drop overlay's dash pattern. |
| `dropPadding` | `static let dropPadding: CGFloat = Space.n24` | The drop overlay's padding. |
| `dropGlyph` | `static let dropGlyph = Icon.n30` | The drop overlay's glyph size. |
| `placeholderTop` | `static func placeholderTop(hue: Double) -> Color { Color(hue: hue, saturation: placeholderSaturationTop, brightness: placeholderBrightnessTop) }` | The top half of a generated placeholder. |
| `placeholderBottom` | `static func placeholderBottom(hue: Double) -> Color { Color(hue: hue, saturation: placeholderSaturationBottom, brightness: placeholderBrightnessBottom) }` | The bottom half of a generated placeholder. |
| `placeholderGlyph` | `static let placeholderGlyph = Icon.n34` | The placeholder art glyph size. |
| `emptyStateGlyph` | `static let emptyStateGlyph = Icon.n42` | The empty-state glyph size. |
| `progressHeight` | `static let progressHeight: CGFloat = Space.n3` | The small progress bar's height. |
| `placeholderSaturationTop` | `static let placeholderSaturationTop: CGFloat = 0.42` | The placeholder art's top saturation. |
| `placeholderBrightnessTop` | `static let placeholderBrightnessTop: CGFloat = 0.34` | The placeholder art's top brightness. |
| `placeholderSaturationBottom` | `static let placeholderSaturationBottom: CGFloat = 0.50` | The placeholder art's bottom saturation. |
| `placeholderBrightnessBottom` | `static let placeholderBrightnessBottom: CGFloat = 0.18` | The placeholder art's bottom brightness. |
| `hoverScale` | `static let hoverScale: CGFloat = 1.02` | The Continue Watching card's hover scale. |
| `cardHoverScale` | `static let cardHoverScale: CGFloat = 1.015` | The library card's hover scale. |

## Inspector

| Token | Declaration | Purpose |
|---|---|---|
| `errorBannerMaximumHeight` | `static let errorBannerMaximumHeight: CGFloat = 240` | Caps recovery content so the assistant composer remains reachable. |
| `errorDetailsMaximumHeight` | `static let errorDetailsMaximumHeight: CGFloat = 100` | Bounds long provider diagnostics inside the recovery banner. |
| `contextPreviewHeight` | `static let contextPreviewHeight: CGFloat = 180` | Height reserved for the scrollable attachment preview. |
| `minimumWidth` | `static let minimumWidth: CGFloat = Size.n260` | The narrowest useful transcript column. |
| `idealWidth` | `static let idealWidth: CGFloat = Size.n360` | The default column width beside a 16:9 surface. |
| `maximumWidth` | `static let maximumWidth: CGFloat = Size.n420` | The widest the column may grow before the video shrinks too far. |

## Player HUD

| Token | Declaration | Purpose |
|---|---|---|
| `capsuleHorizontal` | `static let capsuleHorizontal: CGFloat = Space.n10` | The utility capsule's horizontal padding. |
| `capsuleVertical` | `static let capsuleVertical: CGFloat = Space.n5` | The utility capsule's vertical padding. |
| `capsuleCorner` | `static let capsuleCorner = Radius.capsule` | The utility capsule's corner. |
| `metadataSpacing` | `static let metadataSpacing: CGFloat = Space.n2` | The metadata block's gap. |
| `controlSpacing` | `static let controlSpacing: CGFloat = Space.n8` | The transport stack's gap. |
| `topMargin` | `static let topMargin: CGFloat = Space.n24` | The top controls' margin. |
| `topLeadingWindow` | `static let topLeadingWindow: CGFloat = Space.n84` | The top controls' leading margin when the window is not full screen. |
| `topLeadingFullScreen` | `static let topLeadingFullScreen: CGFloat = Space.n24` | The top controls' leading margin in full screen. |
| `bottomMargin` | `static let bottomMargin: CGFloat = Space.n40` | The bottom controls' horizontal margin. |
| `metadataBottomGap` | `static let metadataBottomGap: CGFloat = Space.n14` | The metadata's gap above the timeline. |
| `metadataTrailingGap` | `static let metadataTrailingGap: CGFloat = Space.n16` | The gap between the metadata and the trailing controls. |
| `timelineBottom` | `static let timelineBottom: CGFloat = Space.n28` | The timeline's bottom margin. |
| `timelineHeight` | `static let timelineHeight: CGFloat = Space.n28` | The timeline's height. |
| `timelineCorner` | `static let timelineCorner = Radius.timeline` | The timeline glass's corner. |
| `transportOffset` | `static let transportOffset: CGFloat = Space.n24` | The transport's vertical offset. |
| `topShadeHeight` | `static let topShadeHeight: CGFloat = Size.n140` | The top shade's maximum height. |
| `topShadeFraction` | `static let topShadeFraction: CGFloat = 0.3` | The top shade's share of the window height. |
| `bottomShadeHeight` | `static let bottomShadeHeight: CGFloat = Size.n220` | The bottom shade's maximum height. |
| `bottomShadeFraction` | `static let bottomShadeFraction: CGFloat = 0.45` | The bottom shade's share of the window height. |
| `playDisc` | `static let playDisc: CGFloat = Size.n96` | The play disc's diameter. |
| `skipDisc` | `static let skipDisc: CGFloat = Size.n64` | The skip disc's diameter. |
| `playPauseSymbol` | `static let playPauseSymbol: CGFloat = Size.n48` | The play/pause symbol's point size. |
| `skipSymbol` | `static let skipSymbol: CGFloat = Size.n30` | The skip symbol's point size. |
| `dockedTransport` | `static let dockedTransport: CGFloat = Size.n24` | The transport's size when the OSC is docked. |
| `capsuleSpacing` | `static let capsuleSpacing: CGFloat = Space.n10` | The gap inside a utility capsule. |
| `volumeCapsuleSpacing` | `static let volumeCapsuleSpacing: CGFloat = Space.n6` | The gap inside the volume capsule. |
| `transportSpacingHUD` | `static let transportSpacingHUD: CGFloat = Space.n28` | The gap between transport controls in the HUD. |
| `transportSpacingLegacy` | `static let transportSpacingLegacy: CGFloat = Space.n16` | The gap between transport controls in the docked bar. |
| `utilityGlyph` | `static let utilityGlyph = Icon.n16` | A utility glyph's point size. |
| `volumeGlyph` | `static let volumeGlyph = Icon.n14` | The volume glyph's point size. |
| `titleFont` | `static let titleFont = Typography.detailTitleStrong` | The title's font. |
| `subtitleFont` | `static let subtitleFont = Typography.caption` | The subtitle's font. |
| `discCorner` | `static func discCorner(for diameter: CGFloat) -> CGFloat { diameter / 2 }` | The transport disc's glass corner is half its diameter. |

## Settings

| Token | Declaration | Purpose |
|---|---|---|
| `sectionSpacing` | `static let sectionSpacing: CGFloat = Space.n16` | The gap between sections. |
| `cardCorner` | `static let cardCorner = Radius.settingsCard` | The settings card's corner. |
| `indicatorOffset` | `static let indicatorOffset: CGFloat = Space.n8` | The section indicator's offset. |
| `sectionRowHeight` | `static let sectionRowHeight: CGFloat = Size.n22` | The vertical step between section indicator rows. |
| `sectionIndicatorAnimation` | `static let sectionIndicatorAnimation = Motion.n10` | The section indicator's animation. |
| `contentWidth` | `static let contentWidth = Size.settingsContentWidth` | The settings content's width. |
| `sidebarWidth` | `static let sidebarWidth = Size.settingsSidebarWidth` | The settings sidebar's width. |
| `windowWidth` | `static let windowWidth = Size.settingsWindowWidth` | The settings window's width. |
| `sidebarMaximum` | `static let sidebarMaximum = Size.n220` | The settings sidebar's maximum width. |
| `contentMinimum` | `static let contentMinimum = Size.n430` | The settings content's minimum width. |
| `previewMinimumHeight` | `static let previewMinimumHeight = Size.n120` | The settings preview's minimum height. |
| `previewMaximumHeight` | `static let previewMaximumHeight = Size.n400` | The settings preview's maximum height. |

## Aspect

| Token | Declaration | Purpose |
|---|---|---|
| `video` | `static let video: CGFloat = 16.0 / 9.0` | 16:9, the shape of a video frame. |

## Windows

| Token | Declaration | Purpose |
|---|---|---|
| `defaultSize` | `static let defaultSize = Size.window` | The library window's default size. |
| `minimumSize` | `static let minimumSize = Size.minimumWindow` | The library window's minimum size. |

## Component layout tokens

Compact and full values for controls that follow the app's compact-interface preference.

| Token | Declaration | File | Purpose |
|---|---|---|---|
| `sidebarMargin` | `static let sidebarMargin = LayoutValue` | `uniplayer/LayoutValue.swift` | — |
| `sidebarStackViewSpacing` | `static let sidebarStackViewSpacing = LayoutValue` | `uniplayer/LayoutValue.swift` | — |
| `sidebarContainerPadding` | `static let sidebarContainerPadding = LayoutValue` | `uniplayer/LayoutValue.swift` | — |
| `sidebarItemSpacing` | `static let sidebarItemSpacing = LayoutValue` | `uniplayer/LayoutValue.swift` | — |
| `topPadding` | `static let topPadding = LayoutValue` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `bottomPadding` | `static let bottomPadding = LayoutValue` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `controlTopPadding` | `static let controlTopPadding = LayoutValue` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `titleSliderSpacing` | `static let titleSliderSpacing = LayoutValue` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `oscPadding` | `static let oscPadding = LayoutValue` | `uniplayer/OSCBottomView.swift` | — |
| `oscPaddingLeading` | `static let oscPaddingLeading = LayoutValue` | `uniplayer/OSCBottomView.swift` | — |
| `oscPaddingTop` | `static let oscPaddingTop = LayoutValue` | `uniplayer/OSCFloatingView.swift` | — |
| `oscPaddingBottom` | `static let oscPaddingBottom = LayoutValue` | `uniplayer/OSCFloatingView.swift` | — |
| `sidebarSettingsSpacing` | `static let sidebarSettingsSpacing = LayoutValue` | `uniplayer/SidebarLayoutPane.swift` | — |
| `liquidGlassSettingsSpacing` | `static let liquidGlassSettingsSpacing = LayoutValue` | `uniplayer/SidebarLayoutPane.swift` | — |
| `toolbarPaddingVertical` | `static let toolbarPaddingVertical = LayoutValue` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `toolbarPaddingHorizontal` | `static let toolbarPaddingHorizontal = LayoutValue` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `tableRowHeight` | `static let tableRowHeight = LayoutValue` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `titlebarHeight` | `static let titlebarHeight = LayoutValue` | `uniplayer/Titlebar.swift` | — |
| `oscBottomMargin` | `static let oscBottomMargin = LayoutValue` | `uniplayer/Titlebar.swift` | — |

## Interface Builder exceptions

Interface Builder cannot reference Swift tokens. These are the only
non-system values permitted; each is keyed to its exact file and value.

| File | Key | Value | Reason |
|---|---|---|---|
| `uniplayer/Base.lproj/PrefSubViewController.xib` | `color` | `red=0.05813049898,green=0.055541899059999997,blue=1,alpha=1,colorSpace=calibratedRGB` | default colour for a subtitle colour well (user data) |
