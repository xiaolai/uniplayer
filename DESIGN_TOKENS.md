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
| AppKit and SwiftUI sources | 100 % tokenised; lint-enforced |
| Interface Builder documents | System catalog colours and `metaFont`s; the custom values below are the remaining exceptions |
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

## Palette · System

| Token | Declaration | Purpose |
|---|---|---|
| `textPrimary` | `ColorToken(nsColor: .labelColor)` | The primary text colour. |
| `textSecondary` | `ColorToken(nsColor: .secondaryLabelColor)` | Supporting text, such as subtitles and metadata. |
| `textTertiary` | `ColorToken(nsColor: .tertiaryLabelColor)` | The least prominent text, such as counts and hints. |
| `textDisabled` | `ColorToken(nsColor: .disabledControlTextColor)` | Text on a disabled control. |
| `controlText` | `ColorToken(nsColor: .controlTextColor)` | Text inside an editable control. |
| `documentText` | `ColorToken(nsColor: .textColor)` | Text in a document or text view. |
| `selectedText` | `ColorToken(nsColor: .selectedTextColor)` | Text under a selection. |
| `accent` | `ColorToken(nsColor: .controlAccentColor)` | The user's accent colour. |
| `highlight` | `ColorToken(nsColor: .highlightColor)` | The selection highlight colour. |
| `separator` | `ColorToken(nsColor: .separatorColor)` | Hairlines and separators. |
| `grid` | `ColorToken(nsColor: .gridColor)` | Table grids. |
| `windowBackground` | `ColorToken(nsColor: .windowBackgroundColor)` | A window's backing colour. |
| `controlBackground` | `ColorToken(nsColor: .controlBackgroundColor)` | The backing of a control. |
| `destructive` | `ColorToken(nsColor: .systemRed)` | The system's destructive colour. |
| `systemBlue` | `ColorToken(nsColor: .systemBlue)` | The system's blue, used by the legacy guide overlay. |
| `systemGreen` | `ColorToken(nsColor: .systemGreen)` | The system's green. |
| `systemOrange` | `ColorToken(nsColor: .systemOrange)` | The system's orange. |
| `systemBlueHighlight` | `ColorToken(nsColor: .systemBlue.highlight(withLevel: 0.1) ?? .systemBlue)` | The guide overlay's highlighted fill. |
| `currentContrast` | `static var currentContrast: ColorToken {` | The colour that contrasts with the current drawing appearance. |
| `white` | `ColorToken(nsColor: .white)` | Opaque white. |
| `black` | `ColorToken(nsColor: .black)` | Opaque black. |
| `gray` | `ColorToken(nsColor: .gray)` | The system's mid grey. |
| `clear` | `ColorToken(nsColor: .clear)` | No colour. |

## Palette · Library

| Token | Declaration | Purpose |
|---|---|---|
| `canvas` | `ColorToken.dynamic(light: 0xF2F2F5, dark: 0x0E0E12)` | The page behind the shelves. |
| `sidebar` | `ColorToken.dynamic(light: 0xE9E9EE, dark: 0x15151A)` | The sidebar and other chrome that sits beside the content. |
| `surface` | `ColorToken.dynamic(light: 0xFFFFFF, dark: 0x1C1C22)` | A raised surface: cards, sheets and the search field's backing. |

## Palette · Media

| Token | Declaration | Purpose |
|---|---|---|
| `onMedia` | `white` | The primary text colour over media. |
| `onMediaSecondary` | `white.alpha(0.78)` | Supporting text over media. |
| `onMediaTertiary` | `white.alpha(0.72)` | Progress and other secondary detail over media. |
| `onMediaSubtitle` | `white.alpha(0.68)` | A HUD subtitle over media. |
| `onMediaFaint` | `white.alpha(0.34)` | A decorative glyph over media. |
| `cardShade` | `black.alpha(0.78)` | The shade that makes text legible at the bottom of a card. |
| `heroShade` | `black.alpha(0.88)` | The shade that makes text legible at the bottom of a hero. |
| `heroGradientMid` | `black.alpha(0.18)` | The first stop of the hero gradient. |
| `detailGradientMid` | `black.alpha(0.15)` | The first stop of the detail gradient. |
| `detailGradientEnd` | `black.alpha(0.84)` | The detail page's final gradient stop. |

## Palette · Borders

| Token | Declaration | Purpose |
|---|---|---|
| `mediaBorder` | `white.alpha(0.08)` | A card's resting border over media. |
| `mediaBorderHover` | `white.alpha(0.28)` | A card's hover border over media. |
| `mediaBorderHoverStrong` | `white.alpha(0.34)` | A stronger hover border used by the continue-watching card. |
| `mediaBorderIncreased` | `white.alpha(0.5)` | A border that survives Increase Contrast. |
| `mediaBorderIncreasedStrong` | `white.alpha(0.65)` | A stronger border for Increase Contrast. |

## Palette · Player HUD

| Token | Declaration | Purpose |
|---|---|---|
| `hudScrim` | `black.alpha(0.30)` | The dark scrim over the video when the HUD is visible. |
| `hudScrimIncreased` | `black.alpha(0.45)` | The scrim used when Increase Contrast is on. |
| `hudTopShade` | `black.alpha(0.62)` | The top gradient behind the utility controls. |
| `hudBottomShade` | `black.alpha(0.84)` | The bottom gradient behind metadata and the timeline. |
| `hudGlassTint` | `black.alpha(0.45)` | The tint inside a clear Liquid Glass capsule. |
| `hudDiscGlassTint` | `black.alpha(0.55)` | The tint inside a regular Liquid Glass transport disc. |
| `hudDiscBackground` | `ColorToken(nsColor: NSColor(white: 0.13, alpha: 0.9))` | The opaque backing under a transport disc before glass is applied. |
| `hudControlBorder` | `white.alpha(0.8)` | A white border on a HUD control. |
| `hudVolumeFill` | `white.alpha(0.92)` | The volume slider's played portion inside the HUD. |
| `hudVolumeTrack` | `white.alpha(0.22)` | The volume slider's unplayed portion inside the HUD. |
| `progressTrack` | `white.alpha(0.26)` | The track behind a small progress bar over media. |

## Palette · Legacy asset colours

| Token | Declaration | Purpose |
|---|---|---|
| `initialWindowLastFile` | `ColorToken(nsColor: .initialWindowLastFileBackground)` | The initial window's recent-file row. |
| `initialWindowLastFileHover` | `ColorToken(nsColor: .initialWindowLastFileBackgroundHover)` | The initial window's recent-file row on hover. |
| `initialWindowLastFilePressed` | `ColorToken(nsColor: .initialWindowLastFileBackgroundPressed)` | The initial window's recent-file row while pressed. |
| `initialWindowBetaLabel` | `ColorToken(nsColor: .initialWindowBetaLabel)` | The beta channel label. |
| `initialWindowDebugLabel` | `ColorToken(nsColor: .initialWindowDebugLabel)` | The debug channel label. |
| `initialWindowNightlyLabel` | `ColorToken(nsColor: .initialWindowNightlyLabel)` | The nightly channel label. |
| `mainSliderKnob` | `ColorToken(nsColor: .mainSliderKnob)` | The main slider's knob. |
| `mainSliderKnobActive` | `ColorToken(nsColor: .mainSliderKnobActive)` | The main slider's knob while active. |
| `mainSliderBarLeft` | `ColorToken(nsColor: .mainSliderBarLeft)` | The main slider's played portion. |
| `mainSliderBarRight` | `ColorToken(nsColor: .mainSliderBarRight)` | The main slider's unplayed portion. |
| `mainSliderLoopKnob` | `ColorToken(nsColor: .mainSliderLoopKnob)` | The main slider's loop knob. |
| `volumeSliderBarLeft` | `ColorToken(nsColor: .volumeSliderBarLeft)` | The volume slider's played portion. |
| `volumeSliderBarRight` | `ColorToken(nsColor: .volumeSliderBarRight)` | The volume slider's unplayed portion. |
| `sidebarContainerBorder` | `ColorToken(nsColor: .sidebarContainerBorder)` | The sidebar container border. |
| `sidebarTabButtonBorder` | `ColorToken(nsColor: .sidebarTabBtnBorder)` | The sidebar tab button border. |
| `sidebarTableBackground` | `ColorToken(nsColor: .sidebarTableBackground)` | The sidebar table backing. |
| `sidebarTabTint` | `ColorToken(nsColor: .sidebarTabTint)` | An inactive sidebar tab's tint. |
| `sidebarTabTintActive` | `ColorToken(nsColor: .sidebarTabTintActive)` | The active sidebar tab's tint. |
| `titleBarBorder` | `ColorToken(nsColor: .titleBarBorder)` | The titlebar's bottom border. |
| `cropBoxFill` | `ColorToken(nsColor: .cropBoxFill)` | The crop box's fill. |
| `playlistProgressBar` | `ColorToken(nsColor: .playlistProgressBar)` | The playlist progress bar. |

## Palette · Legacy computed colours

| Token | Declaration | Purpose |
|---|---|---|
| `keyRecordBackground` | `ColorToken(nsColor: .controlBackgroundColor.withSystemEffect(.disabled))` | A key-record view at rest. |
| `keyRecordBackgroundActive` | `ColorToken(nsColor: .controlBackgroundColor)` | An active key-record view. |
| `inspectorWatchBackground` | `ColorToken(nsColor: NSColor(red: 2.0 / 3, green: 2.0 / 3, blue: 2.0 / 3, alpha: 0.1))` | The inspector watch table's backing. |
| `inspectorWatchHeader` | `ColorToken(nsColor: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))` | The inspector watch table's column header. |
| `preferenceTabPressed` | `ColorToken(nsColor: .windowBackgroundColor.withSystemEffect(.pressed))` | The pressed background of a preference tab. |
| `aboutGradient` | `ColorToken(nsColor: NSColor(white: 0.925, alpha: 1))` | The app name's gradient base in About. |
| `accentBlend` | `ColorToken(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.2, of: .white) ?? .controlAccentColor)` | The accent colour lightened for the playlist selection. |
| `sidebarFillSubtle` | `ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.1))` | A translucent grey used by sidebars and selection pills. |
| `sidebarFill` | `ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.15))` | A stronger translucent grey used by sidebars and selection pills. |
| `sidebarFillStrong` | `ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.2))` | The strongest translucent grey in the sidebar. |
| `permissionWarningFill` | `ColorToken(nsColor: NSColor.systemRed.withAlphaComponent(0.3))` | A red-tinted permission warning box. |
| `sidebarShadow` | `black.alpha(0.3)` | The legacy shadow under a sidebar tab. |
| `panelShadow` | `black.alpha(0.5)` | The legacy shadow under a floating panel. |
| `guideShadow` | `black.alpha(0.5)` | The guide overlay's shadow. |
| `shadow` | `black.alpha(0.5)` | The generic black shadow used by legacy AppKit views. |
| `subtitleBorder` | `black` | The subtitle overlay's border. |
| `subtitleShadow` | `black` | The subtitle overlay's shadow. |
| `selectedSegmentText` | `white` | Text on a selected toolbar segment. |
| `segmentSeparator` | `white.alpha(0.8)` | The separator inside a segmented control. |
| `inspectorDisabledText` | `textDisabled` | The inspector's disabled row text. |
| `settingsCardBorder` | `black.alpha(0.08)` | The settings card's border. |
| `settingsCardBorderSubtle` | `black.alpha(0.05)` | The subtler border used by the settings page container. |
| `settingsCardFill` | `black.alpha(0.02)` | The settings card's fill. |
| `settingsSelection` | `ColorToken(nsColor: .highlightColor).alpha(0.1)` | A selected settings item. |
| `settingsSelectionStrong` | `ColorToken(nsColor: .highlightColor).alpha(0.2)` | A strongly selected settings item. |
| `screenshotBorder` | `ColorToken(nsColor: .gridColor).alpha(0.6)` | The screenshot preview's border. |
| `tableOverlay` | `white.alpha(0.05)` | A faint white overlay on a dark table. |
| `touchBarStroke` | `ColorToken(nsColor: .labelColor).alpha(0.4)` | A stroke on the Touch Bar preview. |
| `placeholderFill` | `ColorToken(nsColor: .gray).alpha(0.2)` | The placeholder tile behind a missing plugin icon. |
| `logError` | `ColorToken(nsColor: .systemRed)` | A log entry at the error level. |
| `logWarning` | `ColorToken(nsColor: .systemOrange)` | A log entry at the warning level. |
| `logDebug` | `ColorToken(nsColor: .gray)` | A log entry at the debug or verbose level. |
| `logInfo` | `ColorToken(nsColor: .systemBlue)` | A log entry at the information level. |
| `logSuccess` | `ColorToken(nsColor: .systemGreen)` | A log entry at the success level. |

## Typography · Library roles

| Token | Declaration | Purpose |
|---|---|---|
| `heroTitle` | `FontToken(size: 34, weight: .bold)` | A hero's title. |
| `heroBody` | `FontToken(size: 15, weight: .regular)` | A hero's supporting line. |
| `sectionTitle` | `FontToken(size: 17, weight: .semibold)` | A page or section heading. |
| `pageTitle` | `FontToken(size: 26, weight: .bold)` | A page title above a grid. |
| `cardTitle` | `FontToken(size: 13, weight: .semibold)` | A card's title. |
| `body` | `FontToken(size: NSFont.systemFontSize, weight: .regular)` | Body copy. |
| `button` | `FontToken(size: NSFont.systemFontSize, weight: .medium)` | A button's label. |
| `bodyStrong` | `FontToken(size: NSFont.systemFontSize, weight: .bold)` | Emphasised body copy. |
| `captionStrong` | `FontToken(size: NSFont.smallSystemFontSize, weight: .bold)` | A bold caption. |
| `size12Strong` | `FontToken(size: 12, weight: .bold)` | A bold 12 pt label. |
| `menuNumeric` | `FontToken(size: 0, weight: .regular, family: .monospacedDigit)` | The menu's numeric font, sized by the system. |
| `monoTitle` | `FontToken(size: 18, weight: .bold, family: .monospaced)` | An 18 pt bold monospaced title. |
| `devBadge` | `FontToken(size: NSFont.smallSystemFontSize * 0.8, weight: .bold)` | The small developer badge, which is slightly smaller than a caption. |
| `urlField` | `FontToken(size: 20, weight: .regular)` | The URL field in the Open URL sheet. |
| `loading` | `FontToken(size: 16, weight: .regular)` | The loading label in the Open URL sheet. |
| `keyRecord` | `FontToken(size: 22, weight: .regular, family: .monospaced)` | The recorded-key display. |
| `codeSample` | `FontToken(size: 12, weight: .regular, family: .monospaced)` | A code sample shown in settings. |
| `preview` | `FontToken(size: 24, weight: .regular)` | The font-picker preview. |
| `systemFont` | `.regular) -> NSFont {` | A system font at a dynamic size, for text that scales with user settings. |
| `monoFont` | `.regular) -> NSFont {` | A monospaced font at a dynamic size. |
| `numericFont` | `.regular) -> NSFont {` | A tabular-figure font at a dynamic size. |
| `namedFont` | `static func namedFont(name: String, size: CGFloat) -> NSFont {` | A font chosen by the user, at a tokenised size. |
| `caption` | `FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | The smallest supporting line. |
| `searchField` | `FontToken(size: 15, weight: .regular)` | The search field's text. |

## Typography · App roles

| Token | Declaration | Purpose |
|---|---|---|
| `appTitle` | `FontToken(size: 20, weight: .bold)` | The app name in the initial window. |
| `aboutTitle` | `FontToken(size: 24, weight: .light)` | The app name in About. |
| `detailTitle` | `FontToken(size: 18, weight: .regular)` | A dialog or detail title. |
| `detailTitleStrong` | `FontToken(size: 18, weight: .semibold)` | An emphasised dialog title. |
| `settingsTitle` | `FontToken(size: 14, weight: .bold)` | A settings page title. |
| `settingsRowTitle` | `FontToken(size: 15, weight: .regular)` | A settings row title. |
| `sidebarSection` | `FontToken(size: 12, weight: .bold)` | A sidebar section title. |
| `sidebarItem` | `FontToken(size: 11, weight: .regular)` | A sidebar item label. |
| `sidebarCaption` | `FontToken(size: 10, weight: .regular)` | A small sidebar label. |
| `badge` | `FontToken(size: 9, weight: .regular)` | A tag or badge. |
| `badgeStrong` | `FontToken(size: 9, weight: .bold)` | A small badge. |

## Typography · Numeric and monospaced

| Token | Declaration | Purpose |
|---|---|---|
| `numeric` | `FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospacedDigit)` | Tabular figures for a time or duration. |
| `numericBody` | `FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospacedDigit)` | Tabular figures at body size. |
| `numericTitle` | `FontToken(size: 18, weight: .bold, family: .monospacedDigit)` | A bold time display. |
| `mono` | `FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)` | A monospaced body, for logs and code. |
| `monoCaption` | `FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospaced)` | A monospaced caption. |
| `monoKey` | `FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)` | A monospaced key label. |

## Typography · Menu and control variants

| Token | Declaration | Purpose |
|---|---|---|
| `menu` | `FontToken(size: 0, weight: .regular, family: .system)` | The system menu font. |
| `message` | `FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | The system message font size. |
| `label` | `FontToken(size: NSFont.systemFontSize, weight: .regular)` | The system label font size. |

## Typography · Raw ramp

| Token | Declaration | Purpose |
|---|---|---|
| `size9` | `FontToken(size: 9, weight: .regular)` | 9 pt, for the smallest labels that predate the role ramp. |
| `size10` | `FontToken(size: 10, weight: .regular)` | 10 pt supporting text. |
| `size11` | `FontToken(size: NSFont.smallSystemFontSize, weight: .regular)` | 11 pt system text. |
| `size12` | `FontToken(size: 12, weight: .regular)` | 12 pt text. |
| `size13` | `body` | 13 pt system text. |
| `size13_5` | `FontToken(size: 13.5, weight: .regular)` | 13.5 pt, used by toolbar symbols. |
| `size14` | `FontToken(size: 14, weight: .regular)` | 14 pt text. |
| `size15` | `searchField` | 15 pt text. |
| `size16` | `FontToken(size: 16, weight: .regular)` | 16 pt text. |
| `size18` | `detailTitle` | 18 pt text. |
| `size20` | `FontToken(size: 20, weight: .regular)` | 20 pt text. |
| `size24` | `aboutTitle` | 24 pt text. |
| `size26` | `pageTitle` | 26 pt text. |
| `size30` | `FontToken(size: 30, weight: .regular)` | 30 pt text. |
| `size34` | `heroTitle` | 34 pt text. |
| `size42` | `FontToken(size: 42, weight: .light)` | 42 pt text. |

## Space

| Token | Declaration | Purpose |
|---|---|---|
| `n0` | `0` | 0 pt. |
| `n1` | `1` | 1 pt. |
| `n2` | `2` | 2 pt. |
| `n2_5` | `2.5` | 2.5 pt. |
| `n3` | `3` | 3 pt. |
| `n4` | `4` | 4 pt. |
| `n5` | `5` | 5 pt. |
| `n6` | `6` | 6 pt. |
| `n8` | `8` | 8 pt. |
| `n9` | `9` | 9 pt. |
| `n10` | `10` | 10 pt. |
| `n11` | `11` | 11 pt. |
| `n12` | `12` | 12 pt. |
| `n14` | `14` | 14 pt. |
| `n15` | `15` | 15 pt. |
| `n16` | `16` | 16 pt. |
| `n18` | `18` | 18 pt. |
| `n20` | `20` | 20 pt. |
| `n24` | `24` | 24 pt. |
| `n25` | `25` | 25 pt. |
| `n26` | `26` | 26 pt. |
| `n28` | `28` | 28 pt. |
| `n30` | `30` | 30 pt. |
| `n32` | `32` | 32 pt. |
| `n36` | `36` | 36 pt. |
| `n45` | `45` | 45 pt. |
| `n40` | `40` | 40 pt. |
| `n48` | `48` | 48 pt. |
| `n52` | `52` | 52 pt. |
| `n60` | `60` | 60 pt. |
| `n64` | `64` | 64 pt. |
| `n68` | `68` | 68 pt. |
| `n80` | `80` | 80 pt. |
| `n84` | `84` | 84 pt. |
| `n86` | `86` | 86 pt, the titlebar's leading inset that clears the traffic lights. |
| `n200` | `200` | 200 pt. |
| `n260` | `260` | 260 pt. |
| `n300` | `300` | 300 pt. |

## Spacing · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `controlGap` | `n8` | The gap between related controls. |
| `rowGap` | `n12` | The gap between rows in a stack. |
| `titleGap` | `n12` | The gap between a title and its shelf. |
| `sectionGap` | `n32` | The gap between sections. |
| `pageMargin` | `n40` | The page's horizontal margin. |
| `pageTop` | `n24` | The page's top margin. |
| `pageBottom` | `n48` | The page's bottom margin. |

## Radius

| Token | Declaration | Purpose |
|---|---|---|
| `n0` | `0` | 0 pt. |
| `n1` | `1` | 1 pt. |
| `n1_5` | `1.5` | 1.5 pt. |
| `n2` | `2` | 2 pt. |
| `n2_5` | `2.5` | 2.5 pt. |
| `n3` | `3` | 3 pt. |
| `n4` | `4` | 4 pt. |
| `n6` | `6` | 6 pt. |
| `n8` | `8` | 8 pt. |
| `n10` | `10` | 10 pt. |
| `n11` | `11` | 11 pt. |
| `n12` | `12` | 12 pt. |
| `n14` | `14` | 14 pt. |
| `n15` | `15` | 15 pt. |
| `n16` | `16` | 16 pt. |
| `n18` | `18` | 18 pt. |

## Radius · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `card` | `n10` | A card's corner. |
| `hero` | `n14` | A hero's corner. |
| `capsule` | `n15` | A HUD capsule's corner. |
| `timeline` | `n14` | The HUD timeline's corner. |
| `settingsCard` | `{` | A settings card's corner, which follows the platform's control shape. |
| `control` | `n4` | A small control's corner. |
| `sidebarContainer` | `n8` | A sidebar container's corner. |
| `panel` | `n10` | A floating panel's corner. |

## Stroke

| Token | Declaration | Purpose |
|---|---|---|
| `none` | `0` | No stroke. |
| `hairline` | `1` | A hairline. |
| `n0_4` | `0.4` | 0.4 pt, the legacy slider outline. |
| `n1_5` | `1.5` | 1.5 pt. |
| `n4` | `4` | 4 pt. |
| `strong` | `2` | A prominent border. |
| `focus` | `3` | A focus ring. |

## Blur

| Token | Declaration | Purpose |
|---|---|---|
| `n1` | `1` | 1 pt. |
| `n2` | `2` | 2 pt. |
| `n4` | `4` | 4 pt. |
| `n6` | `6` | 6 pt. |
| `n8` | `8` | 8 pt. |
| `n10` | `10` | 10 pt. |

## Opacity

| Token | Declaration | Purpose |
|---|---|---|
| `n00` | `0` | 0. |
| `n02` | `0.02` | 0.02. |
| `n05` | `0.05` | 0.05. |
| `n08` | `0.08` | 0.08. |
| `n10` | `0.10` | 0.10. |
| `n12` | `0.12` | 0.12. |
| `n15` | `0.15` | 0.15. |
| `n18` | `0.18` | 0.18. |
| `n20` | `0.20` | 0.20. |
| `n22` | `0.22` | 0.22. |
| `n26` | `0.26` | 0.26. |
| `n28` | `0.28` | 0.28. |
| `n30` | `0.30` | 0.30. |
| `n34` | `0.34` | 0.34. |
| `n35` | `0.35` | 0.35. |
| `n40` | `0.40` | 0.40. |
| `n45` | `0.45` | 0.45. |
| `n50` | `0.50` | 0.50. |
| `n55` | `0.55` | 0.55. |
| `n60` | `0.60` | 0.60. |
| `n62` | `0.62` | 0.62. |
| `n65` | `0.65` | 0.65. |
| `n68` | `0.68` | 0.68. |
| `n72` | `0.72` | 0.72. |
| `n78` | `0.78` | 0.78. |
| `n80` | `0.80` | 0.80. |
| `n84` | `0.84` | 0.84. |
| `n88` | `0.88` | 0.88. |
| `n90` | `0.90` | 0.90. |
| `n92` | `0.92` | 0.92. |
| `n96` | `0.96` | 0.96. |
| `n98` | `0.98` | 0.98. |
| `disabled` | `n40` | A disabled control's opacity. |
| `border` | `n08` | A resting border. |
| `borderHover` | `n28` | A hover border. |
| `scrim` | `n30` | The HUD's scrim. |

## Size

| Token | Declaration | Purpose |
|---|---|---|
| `n0` | `0` | 0 pt. |
| `n1` | `1` | 1 pt. |
| `n3` | `3` | 3 pt. |
| `n0_75` | `0.75` | 0.75 pt. |
| `n10` | `10` | 10 pt. |
| `n11` | `11` | 11 pt. |
| `n12` | `12` | 12 pt. |
| `n14` | `14` | 14 pt. |
| `n24` | `24` | 24 pt. |
| `n25` | `25` | 25 pt. |
| `n2_5` | `2.5` | 25 pt. |
| `n26` | `26` | 26 pt. |
| `n28` | `28` | 28 pt. |
| `n30` | `30` | 30 pt. |
| `n31` | `31` | 31 pt. |
| `n36` | `36` | 36 pt. |
| `n37` | `37` | 37 pt. |
| `n42` | `42` | 42 pt. |
| `n48` | `48` | 48 pt. |
| `n52` | `52` | 52 pt. |
| `n50` | `50` | 50 pt. |
| `n60` | `60` | 60 pt. |
| `n64` | `64` | 64 pt. |
| `n120` | `120` | 120 pt. |
| `n200` | `200` | 200 pt. |
| `n285` | `285` | 285 pt. |
| `n300` | `300` | 300 pt. |
| `n400` | `400` | 400 pt. |
| `n480` | `480` | 480 pt. |
| `n500` | `500` | 500 pt. |
| `n600` | `600` | 600 pt. |
| `n640` | `640` | 640 pt. |
| `n800` | `800` | 800 pt. |
| `n2000` | `2000` | 2000 pt. |
| `n0_5` | `0.5` | 0.5 pt. |
| `n67` | `67` | 67 pt. |
| `n96` | `96` | 96 pt. |
| `n100` | `100` | 100 pt. |
| `n140` | `140` | 140 pt. |
| `n146` | `146` | 146 pt. |
| `n180` | `180` | 180 pt. |
| `n220` | `220` | 220 pt. |
| `n240` | `240` | 240 pt. |
| `n260` | `260` | 260 pt. |
| `n340` | `340` | 340 pt. |
| `n360` | `360` | 360 pt. |
| `n420` | `420` | 420 pt. |
| `n2` | `2` | 2 pt. |
| `n4` | `4` | 4 pt. |
| `n8` | `8` | 8 pt. |
| `n15` | `15` | 15 pt. |
| `n16` | `16` | 16 pt. |
| `n18` | `18` | 18 pt. |
| `n20` | `20` | 20 pt. |
| `n22` | `22` | 22 pt. |
| `n32` | `32` | 32 pt. |
| `n45` | `45` | 45 pt. |
| `n40` | `40` | 40 pt. |
| `n70` | `70` | 70 pt. |
| `n80` | `80` | 80 pt. |
| `n105_6` | `105.6` | 105.6 pt. |
| `n108` | `108` | 108 pt. |
| `n150` | `150` | 150 pt. |
| `n59_4` | `59.4` | 59.4 pt. |
| `n440` | `440` | 440 pt. |
| `n450` | `450` | 450 pt. |
| `n520` | `520` | 520 pt. |
| `n560` | `560` | 560 pt. |
| `n54` | `54` | 54 pt. |
| `n82` | `82` | 82 pt. |
| `n68` | `68` | 68 pt. |

## Sizes · Roles

| Token | Declaration | Purpose |
|---|---|---|
| `window` | `NSSize(width: 1220, height: 720)` | The library window's default size. |
| `minimumWindow` | `NSSize(width: 900, height: 560)` | The library window's minimum size. |
| `sidebarWidth` | `220` | The library sidebar's ideal width. |
| `titlebarHeight` | `{` | The titlebar's height: 32 pt on macOS 26 and later, 28 pt before. |
| `settingsSidebarWidth` | `180` | The settings sidebar's width. |
| `settingsContentWidth` | `340` | The settings content's width. |
| `settingsWindowWidth` | `650` | The settings window's width. |
| `inputWidth` | `48` | A numeric input's width. |
| `inputHeight` | `25` | A numeric input's height. |
| `textInputWidth` | `64` | A text input's width. |
| `colorWellHeight` | `24` | A colour well's height. |
| `colorWellWidth` | `30` | A colour well's fallback width. |
| `cardWidth` | `215` | The library card's width. |
| `cardHeight` | `151` | The library card's height. |
| `gridMinimum` | `200` | The minimum adaptive grid item. |
| `gridMaximum` | `280` | The maximum adaptive grid item. |
| `searchFieldWidth` | `420` | The library search field's width. |
| `oscFloatingWidth` | `460` | The floating OSC's width. |
| `imagePreviewWidth` | `480 * 0.22` | The settings screenshot preview's width. |
| `imagePreviewHeight` | `270 * 0.22` | The settings screenshot preview's height. |
| `progressWidth` | `180` | The detail page's progress width. |
| `emptyStateWidth` | `360` | The empty state's message width. |

## Icon

| Token | Declaration | Purpose |
|---|---|---|
| `n10` | `10` | 10 pt. |
| `n11` | `11` | 11 pt. |
| `n12` | `12` | 12 pt. |
| `n13_5` | `13.5` | 13.5 pt. |
| `n14` | `14` | 14 pt. |
| `n15` | `15` | 15 pt. |
| `n16` | `16` | 16 pt. |
| `n18` | `18` | 18 pt. |
| `n20` | `20` | 20 pt. |
| `n24` | `24` | 24 pt. |
| `n25` | `25` | 25 pt. |
| `n2_5` | `2.5` | 25 pt. |
| `n26` | `26` | 26 pt. |
| `n28` | `28` | 28 pt. |
| `n30` | `30` | 30 pt. |
| `n34` | `34` | 34 pt. |
| `n42` | `42` | 42 pt. |
| `n68` | `68` | 68 pt. |

## Motion

| Token | Declaration | Purpose |
|---|---|---|
| `none` | `MotionToken(duration: 0)` | No animation. |
| `n10` | `MotionToken(duration: 0.1, curve: .easeOut)` | 0.1 seconds. |
| `hover` | `MotionToken(duration: 0.16, curve: .easeOut)` | 0.16 seconds; the library's hover and focus motion. |
| `n20` | `MotionToken(duration: 0.2, curve: .easeOut)` | 0.2 seconds. |
| `n24` | `MotionToken(duration: 0.24, curve: .easeIn)` | 0.24 seconds. |
| `n25` | `MotionToken(duration: 0.25, curve: .easeInOut)` | 0.25 seconds. |
| `n30` | `MotionToken(duration: 0.3, curve: .easeOut)` | 0.3 seconds. |
| `n50` | `MotionToken(duration: 0.5, curve: .easeOut)` | 0.5 seconds. |
| `caretBlink` | `1.0` | The caret blink interval. |
| `pulse` | `1.5` | The slowest repeating UI pulse. |
| `window` | `n25` | The standard window-resize animation. |
| `hud` | `n25` | The standard HUD fade. |
| `sidebar` | `n24` | The standard sidebar transition. |
| `settings` | `n25` | The standard settings transition. |

## Material

| Token | Declaration | Purpose |
|---|---|---|
| `popover` | `VisualEffect(material: .popover, blending: .withinWindow, state: .active)` | A popover-style within-window material. |
| `sidebar` | `VisualEffect(material: .sidebar, blending: .withinWindow, state: .active)` | A sidebar material. |
| `titlebar` | `VisualEffect(material: .titlebar, blending: .withinWindow, state: .active)` | A titlebar material. |
| `underWindowBackground` | `VisualEffect(material: .underWindowBackground, blending: .behindWindow, state: .active)` | A window-background material behind the content. |
| `windowBackground` | `VisualEffect(material: .windowBackground, blending: .withinWindow, state: .active)` | A window-background material for footers. |
| `glassCapsule` | `Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)` | The clear Liquid Glass group used by the HUD's utility capsules. |
| `glassTransport` | `Glass(style: .regular, tint: Palette.hudDiscGlassTint, interactive: false)` | The regular Liquid Glass transport disc. |
| `glassTimeline` | `Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)` | The clear Liquid Glass timeline capsule. |
| `glassFallback` | `VisualEffect(material: .popover, blending: .withinWindow, state: .active)` | The opaque fallback used when Liquid Glass is unavailable. |

## Shadow

| Token | Declaration | Purpose |
|---|---|---|
| `card` | `ShadowToken(color: Palette.black.alpha(Opacity.n22), radius: Size.n12, offset: CGSize(width: 0, height: 5))` | A card's resting shadow. |
| `cardHover` | `ShadowToken(color: Palette.black.alpha(Opacity.n28), radius: Size.n14, offset: CGSize(width: 0, height: 6))` | A card's hover shadow. |
| `hero` | `ShadowToken(color: Palette.black.alpha(Opacity.n35), radius: Size.n24, offset: CGSize(width: 0, height: 12))` | A hero's shadow. |
| `icon` | `ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Radius.n2, offset: CGSize(width: 0, height: 1))` | A small icon shadow. |
| `panel` | `ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Radius.n4, offset: CGSize(width: 0, height: 0))` | A floating panel's shadow. |
| `titlebarText` | `ShadowToken(color: Palette.black, radius: Radius.n2, offset: .zero)` | The titlebar text's shadow. |

## Library

| Token | Declaration | Purpose |
|---|---|---|
| `cardSpacing` | `Space.n8` | The vertical gap inside a card. |
| `cardPadding` | `Space.n12` | The padding inside a card. |
| `cardGap` | `Space.n20` | The gap between cards. |
| `shelfSpacing` | `Space.n12` | The gap inside a shelf. |
| `shelfHeaderSpacing` | `Space.n12` | The gap between a shelf's title and its content. |
| `heroSpacing` | `Space.n10` | The gap inside the hero's text block. |
| `heroPadding` | `Space.n32` | The hero's inner padding. |
| `heroButtonHorizontal` | `Space.n18` | The hero button's horizontal padding. |
| `heroButtonVertical` | `Space.n9` | The hero button's vertical padding. |
| `focusRingOutset` | `Space.n3` | The focus ring's outset. |
| `gridRowGap` | `Space.n24` | The grid's row gap. |
| `sidebarMinimum` | `Space.n200` | The sidebar's minimum width. |
| `sidebarMaximum` | `Space.n260` | The sidebar's maximum width. |
| `sidebarVersionInset` | `Space.n16` | The sidebar version label's inset. |
| `sidebarVersionBottom` | `Space.n10` | The sidebar version label's bottom inset. |
| `emptyStateMinimum` | `Size.n260` | The empty state's minimum height. |
| `gridEmptyStateMinimum` | `Size.n300` | The grid page's empty state minimum height. |
| `searchCorner` | `Radius.n10` | The search field's corner. |
| `searchHorizontal` | `Space.n14` | The search field's horizontal padding. |
| `searchVertical` | `Space.n10` | The search field's vertical padding. |
| `searchTop` | `Space.n32` | The search field's top margin. |
| `dropCorner` | `Radius.n18` | The drop overlay's corner. |
| `dropDash` | `[Space.n8, Space.n6]` | The drop overlay's dash pattern. |
| `dropPadding` | `Space.n24` | The drop overlay's padding. |
| `dropGlyph` | `Icon.n30` | The drop overlay's glyph size. |
| `placeholderTop` | `static func placeholderTop(hue: Double) -> Color {` | The top half of a generated placeholder. |
| `placeholderBottom` | `static func placeholderBottom(hue: Double) -> Color {` | The bottom half of a generated placeholder. |
| `placeholderGlyph` | `Icon.n34` | The placeholder art glyph size. |
| `emptyStateGlyph` | `Icon.n42` | The empty-state glyph size. |
| `progressHeight` | `Space.n3` | The small progress bar's height. |
| `placeholderSaturationTop` | `0.42` | The placeholder art's top saturation. |
| `placeholderBrightnessTop` | `0.34` | The placeholder art's top brightness. |
| `placeholderSaturationBottom` | `0.50` | The placeholder art's bottom saturation. |
| `placeholderBrightnessBottom` | `0.18` | The placeholder art's bottom brightness. |

## HUD

| Token | Declaration | Purpose |
|---|---|---|
| `capsuleHorizontal` | `Space.n10` | The utility capsule's horizontal padding. |
| `capsuleVertical` | `Space.n5` | The utility capsule's vertical padding. |
| `capsuleCorner` | `Radius.capsule` | The utility capsule's corner. |
| `metadataSpacing` | `Space.n2` | The metadata block's gap. |
| `controlSpacing` | `Space.n8` | The transport stack's gap. |
| `topMargin` | `Space.n24` | The top controls' margin. |
| `topLeadingWindow` | `Space.n84` | The top controls' leading margin when the window is not full screen. |
| `topLeadingFullScreen` | `Space.n24` | The top controls' leading margin in full screen. |
| `bottomMargin` | `Space.n40` | The bottom controls' horizontal margin. |
| `metadataBottomGap` | `Space.n14` | The metadata's gap above the timeline. |
| `metadataTrailingGap` | `Space.n16` | The gap between the metadata and the trailing controls. |
| `timelineBottom` | `Space.n28` | The timeline's bottom margin. |
| `timelineHeight` | `Space.n28` | The timeline's height. |
| `timelineCorner` | `Radius.timeline` | The timeline glass's corner. |
| `transportOffset` | `Space.n24` | The transport's vertical offset. |
| `topShadeHeight` | `Size.n140` | The top shade's maximum height. |
| `topShadeFraction` | `0.3` | The top shade's share of the window height. |
| `bottomShadeHeight` | `Size.n220` | The bottom shade's maximum height. |
| `bottomShadeFraction` | `0.45` | The bottom shade's share of the window height. |
| `playDisc` | `Size.n96` | The play disc's diameter. |
| `skipDisc` | `Size.n64` | The skip disc's diameter. |
| `playGlyph` | `Size.n37` | The play glyph's point size. |
| `pauseGlyph` | `Size.n31` | The pause glyph's point size. |
| `skipGlyph` | `Size.n30` | The skip glyph's point size. |
| `utilityGlyph` | `Icon.n16` | A utility glyph's point size. |
| `volumeGlyph` | `Icon.n14` | The volume glyph's point size. |
| `titleFont` | `Typography.detailTitleStrong` | The title's font. |
| `subtitleFont` | `Typography.caption` | The subtitle's font. |
| `discCorner` | `static func discCorner(for diameter: CGFloat) -> CGFloat { diameter / 2 }` | The transport disc's glass corner is half its diameter. |

## Settings

| Token | Declaration | Purpose |
|---|---|---|
| `sectionSpacing` | `Space.n16` | The gap between sections. |
| `cardCorner` | `Radius.settingsCard` | The settings card's corner. |
| `indicatorOffset` | `Space.n8` | The section indicator's offset. |
| `contentWidth` | `Size.settingsContentWidth` | The settings content's width. |
| `sidebarWidth` | `Size.settingsSidebarWidth` | The settings sidebar's width. |
| `windowWidth` | `Size.settingsWindowWidth` | The settings window's width. |

## Aspect

| Token | Declaration | Purpose |
|---|---|---|
| `video` | `16.0 / 9.0` | 16:9, the shape of a video frame. |

## Window

| Token | Declaration | Purpose |
|---|---|---|
| `defaultSize` | `Size.window` | The library window's default size. |
| `minimumSize` | `Size.minimumWindow` | The library window's minimum size. |
| `recentRowHeight` | `Size.n28` | The initial window's recent-files row height. |
| `contentInset` | `Space.n24` | The initial window's content inset. |
| `headerGap` | `Space.n12` | The initial window's header gap. |
| `actionGap` | `Space.n12` | The initial window's action gap. |
| `recentRowGap` | `Space.n6` | The initial window's recent-file row gap. |
| `recentRowCorner` | `Radius.n8` | The initial window's recent-row corner. |
## Component layout tokens

Compact and full values for controls that follow the app's compact-interface preference.

| Token | Declaration | File | Purpose |
|---|---|---|---|
| `sidebarMargin` | `static let sidebarMargin = LayoutValue(Tokens.Space.n16, Tokens.Space.n14)` | `uniplayer/LayoutValue.swift` | — |
| `sidebarStackViewSpacing` | `static let sidebarStackViewSpacing = LayoutValue(Tokens.Space.n18, Tokens.Space.n16)` | `uniplayer/LayoutValue.swift` | — |
| `sidebarContainerPadding` | `static let sidebarContainerPadding = LayoutValue(Tokens.Space.n12, Tokens.Space.n10)` | `uniplayer/LayoutValue.swift` | — |
| `sidebarItemSpacing` | `static let sidebarItemSpacing = LayoutValue(Tokens.Space.n12, Tokens.Space.n8)` | `uniplayer/LayoutValue.swift` | — |
| `topPadding` | `static let topPadding = LayoutValue(Tokens.Space.n8, Tokens.Space.n4)` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `bottomPadding` | `static let bottomPadding = LayoutValue(Tokens.Space.n10, Tokens.Space.n8)` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `controlTopPadding` | `static let controlTopPadding = LayoutValue(Tokens.Space.n4, Tokens.Space.n0)` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `titleSliderSpacing` | `static let titleSliderSpacing = LayoutValue(Tokens.Space.n8, Tokens.Space.n6)` | `uniplayer/MiniPlayerWindowController.swift` | — |
| `oscPadding` | `static let oscPadding = LayoutValue(Tokens.Space.n12, Tokens.Space.n8)` | `uniplayer/OSCBottomView.swift` | — |
| `oscPaddingLeading` | `static let oscPaddingLeading = LayoutValue(Tokens.Space.n16, Tokens.Space.n12)` | `uniplayer/OSCBottomView.swift` | — |
| `oscPaddingTop` | `static let oscPaddingTop = LayoutValue(Tokens.Space.n14, Tokens.Space.n10)` | `uniplayer/OSCFloatingView.swift` | — |
| `oscPaddingBottom` | `static let oscPaddingBottom = LayoutValue(Tokens.Space.n8, Tokens.Space.n5)` | `uniplayer/OSCFloatingView.swift` | — |
| `sidebarSettingsSpacing` | `static let sidebarSettingsSpacing = LayoutValue(Tokens.Space.n10, Tokens.Space.n6)` | `uniplayer/SidebarLayoutPane.swift` | — |
| `liquidGlassSettingsSpacing` | `static let liquidGlassSettingsSpacing = LayoutValue(Tokens.Space.n6, Tokens.Space.n5)` | `uniplayer/SidebarLayoutPane.swift` | — |
| `toolbarPaddingVertical` | `static let toolbarPaddingVertical = LayoutValue(Tokens.Space.n10, Tokens.Space.n6)` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `toolbarPaddingHorizontal` | `static let toolbarPaddingHorizontal = LayoutValue(Tokens.Space.n12, Tokens.Space.n10)` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `tableRowHeight` | `static let tableRowHeight = LayoutValue(Tokens.Space.n30, Tokens.Space.n26)` | `uniplayer/SidebarPlaylistPane.swift` | — |
| `titlebarHeight` | `static let titlebarHeight = LayoutValue(Tokens.Size.titlebarHeight + Tokens.Space.n8, Tokens.Size.titlebarHeight)` | `uniplayer/Titlebar.swift` | — |
| `oscBottomMargin` | `static let oscBottomMargin = LayoutValue(Tokens.Space.n10, Tokens.Space.n6)` | `uniplayer/Titlebar.swift` | — |

## Interface Builder exceptions

Interface Builder cannot reference Swift tokens, so these values are the
remaining exceptions. Colour-well defaults are user data, not design values;
the others are candidates to move into code when their view is next touched.

### Custom colours

| Colour | Count | Locations |
|---|---|---|
| `red="0.05813049898" green="0.055541899059999997" blue="1" alpha="1" colorSpace="calibratedRGB"` | 4 | uniplayer/Base.lproj/PrefSubViewController.xib |
