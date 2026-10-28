//
//  DesignTokens.swift
//  uniplayer
//
//  The single source of truth for every appearance value in the app.
//
//  A view may not invent a colour, font, spacing, radius, stroke, opacity,
//  shadow, material or animation duration. It reads a token from this file.
//  `scripts/check-design-tokens.py` enforces that rule, and
//  `DESIGN_TOKENS.md` is generated from the declarations below; keep every
//  token documented and every value in this file only.
//
//  Values follow the macOS 27 Human Interface Guidelines: system semantic
//  colours (which adapt to appearance, Increase Contrast and Reduce
//  Transparency), the system font, and Liquid Glass with an opaque fallback.
//

import AppKit
import SwiftUI

// MARK: - Token primitives

/// A colour with one AppKit and one SwiftUI representation.
///
/// The source value is always an `NSColor` so dynamic (appearance-aware)
/// colours survive the trip into SwiftUI.
struct ColorToken {
  let nsColor: NSColor

  var color: Color { Color(nsColor: nsColor) }

  /// The SwiftUI colour at a tokenised opacity.
  func opacity(_ value: CGFloat) -> Color {
    color.opacity(Double(value))
  }

  /// The same colour with a tokenised alpha component.
  func alpha(_ value: CGFloat) -> ColorToken {
    ColorToken(nsColor: nsColor.withAlphaComponent(value))
  }

  /// A colour that resolves differently in light and dark appearances.
  static func dynamic(light: UInt32, dark: UInt32) -> ColorToken {
    ColorToken(nsColor: .uniplayerDynamic(
      light: NSColor(hex: light),
      dark: NSColor(hex: dark)))
  }

  /// A colour that resolves differently in light and dark appearances.
  static func dynamic(light: NSColor, dark: NSColor) -> ColorToken {
    ColorToken(nsColor: .uniplayerDynamic(light: light, dark: dark))
  }
}

/// A font with one AppKit and one SwiftUI representation.
struct FontToken {
  enum Family {
    case system
    case monospaced
    case monospacedDigit
  }

  let size: CGFloat
  let weight: NSFont.Weight
  var family: Family = .system

  /// A SwiftUI font scaled by the user's interface text-size preference.
  func scaledFont(_ scale: Double) -> Font {
    FontToken(size: size * min(2, max(1, scale)), weight: weight, family: family).font
  }

  var nsFont: NSFont {
    switch family {
    case .system:
      return .systemFont(ofSize: size, weight: weight)
    case .monospaced:
      return .monospacedSystemFont(ofSize: size, weight: weight)
    case .monospacedDigit:
      return .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
  }

  var font: Font {
    switch family {
    case .system:
      return .system(size: size, weight: weight.swiftUI)
    case .monospaced:
      return .system(size: size, weight: weight.swiftUI, design: .monospaced)
    case .monospacedDigit:
      return .system(size: size, weight: weight.swiftUI).monospacedDigit()
    }
  }
}

extension NSFont.Weight {
  var swiftUI: Font.Weight {
    switch self {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
  }
}

/// A duration and curve shared by AppKit and SwiftUI.
struct MotionToken {
  enum Curve {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    var appKit: CAMediaTimingFunctionName {
      switch self {
      case .linear: return .linear
      case .easeIn: return .easeIn
      case .easeOut: return .easeOut
      case .easeInOut: return .easeInEaseOut
      }
    }

    var swiftUI: Animation {
      switch self {
      case .linear: return .linear
      case .easeIn: return .easeIn
      case .easeOut: return .easeOut
      case .easeInOut: return .easeInOut
      }
    }
  }

  let duration: TimeInterval
  var curve: Curve = .easeOut

  /// The SwiftUI animation.
  var animation: Animation { curve.swiftUI(duration: duration) }

  /// The duration AppKit should use, honouring the user's Reduce Motion and
  /// "Disable animations" preferences.
  var appKitDuration: TimeInterval {
    AccessibilityPreferences.adjustedDuration(duration)
  }

  /// Applies this token to the current AppKit animation context.
  func apply(to context: NSAnimationContext) {
    context.duration = appKitDuration
    context.timingFunction = CAMediaTimingFunction(name: curve.appKit)
  }
}

extension MotionToken.Curve {
  fileprivate func swiftUI(duration: TimeInterval) -> Animation {
    switch self {
    case .linear: return .linear(duration: duration)
    case .easeIn: return .easeIn(duration: duration)
    case .easeOut: return .easeOut(duration: duration)
    case .easeInOut: return .easeInOut(duration: duration)
    }
  }
}

/// A drop shadow shared by AppKit and SwiftUI.
struct ShadowToken {
  let color: ColorToken
  let radius: CGFloat
  let offset: CGSize

  /// An AppKit shadow for `NSView.shadow`.
  var appKit: NSShadow {
    let shadow = NSShadow()
    shadow.shadowColor = color.nsColor
    shadow.shadowBlurRadius = radius
    shadow.shadowOffset = offset
    return shadow
  }
}

// MARK: - Tokens

enum Tokens {

  /// UniPlayer supports one appearance, independent of macOS's light/dark choice.
  enum Appearance {
    /// The application and all native window chrome use dark Aqua.
    static let name: NSAppearance.Name = .darkAqua
  }

  // MARK: Palette

  /// Every colour in the app. System semantic colours are preferred because
  /// the platform keeps them legible across appearances and accessibility
  /// settings; custom colours exist only where the product needs one.
  enum Palette {

    // MARK: Palette: System

    /// The primary text colour.
    static let textPrimary = ColorToken(nsColor: .labelColor)
    /// Supporting text, such as subtitles and metadata.
    static let textSecondary = ColorToken(nsColor: .secondaryLabelColor)
    /// The least prominent text, such as counts and hints.
    static let textTertiary = ColorToken(nsColor: .tertiaryLabelColor)
    /// Text on a disabled control.
    static let textDisabled = ColorToken(nsColor: .disabledControlTextColor)
    /// Text inside an editable control.
    static let controlText = ColorToken(nsColor: .controlTextColor)
    /// Text in a document or text view.
    static let documentText = ColorToken(nsColor: .textColor)
    /// Text under a selection.
    static let selectedText = ColorToken(nsColor: .selectedTextColor)
    /// The user's accent colour.
    static let accent = ColorToken(nsColor: .controlAccentColor)
    /// The selection highlight colour.
    static let highlight = ColorToken(nsColor: .highlightColor)
    /// Hairlines and separators.
    static let separator = ColorToken(nsColor: .separatorColor)
    /// Table grids.
    static let grid = ColorToken(nsColor: .gridColor)
    /// A window's backing colour.
    static let windowBackground = ColorToken(nsColor: .windowBackgroundColor)
    /// The backing of a control.
    static let controlBackground = ColorToken(nsColor: .controlBackgroundColor)
    /// The system's destructive colour.
    static let destructive = ColorToken(nsColor: .systemRed)
    /// The system's blue, used by the legacy guide overlay.
    static let systemBlue = ColorToken(nsColor: .systemBlue)
    /// The system's green.
    static let systemGreen = ColorToken(nsColor: .systemGreen)
    /// The system's orange.
    static let systemOrange = ColorToken(nsColor: .systemOrange)
    /// The guide overlay's highlighted fill.
    static let systemBlueHighlight = ColorToken(nsColor: .systemBlue.highlight(withLevel: 0.1) ?? .systemBlue)
    /// The colour that contrasts with the current drawing appearance.
    static var currentContrast: ColorToken {
      ColorToken(nsColor: NSAppearance.currentDrawing().isDark ? .white : .black)
    }
    /// Opaque white.
    static let white = ColorToken(nsColor: .white)
    /// Opaque black.
    static let black = ColorToken(nsColor: .black)
    /// The system's mid grey.
    static let gray = ColorToken(nsColor: .gray)
    /// No colour.
    static let clear = ColorToken(nsColor: .clear)

    // MARK: Palette: Library

    /// The page behind the shelves.
    static let canvas = ColorToken.dynamic(light: 0xF2F2F5, dark: 0x0E0E12)
    /// The sidebar and other chrome that sits beside the content.
    static let sidebar = ColorToken.dynamic(light: 0xE9E9EE, dark: 0x15151A)
    /// A raised surface: cards, sheets and the search field's backing.
    static let surface = ColorToken.dynamic(light: 0xFFFFFF, dark: 0x1C1C22)

    // MARK: Palette: Media

    /// The primary text colour over media.
    static let onMedia = white
    /// Supporting text over media.
    static let onMediaSecondary = white.alpha(0.78)
    /// Progress and other secondary detail over media.
    static let onMediaTertiary = white.alpha(0.72)
    /// A HUD subtitle over media.
    static let onMediaSubtitle = white.alpha(0.68)
    /// A decorative glyph over media.
    static let onMediaFaint = white.alpha(0.34)
    /// The shade that makes text legible at the bottom of a card.
    static let cardShade = black.alpha(0.78)
    /// The shade that makes text legible at the bottom of a hero.
    static let heroShade = black.alpha(0.88)
    /// The first stop of the hero gradient.
    static let heroGradientMid = black.alpha(0.18)
    /// The first stop of the detail gradient.
    static let detailGradientMid = black.alpha(0.15)
    /// The detail page's final gradient stop.
    static let detailGradientEnd = black.alpha(0.84)

    // MARK: Palette: Borders

    /// A card's resting border over media.
    static let mediaBorder = white.alpha(0.08)
    /// A card's hover border over media.
    static let mediaBorderHover = white.alpha(0.28)
    /// A stronger hover border used by the continue-watching card.
    static let mediaBorderHoverStrong = white.alpha(0.34)
    /// A border that survives Increase Contrast.
    static let mediaBorderIncreased = white.alpha(0.5)
    /// A stronger border for Increase Contrast.
    static let mediaBorderIncreasedStrong = white.alpha(0.65)

    // MARK: Palette: Player HUD

    /// The dark scrim over the video when the HUD is visible.
    static let hudScrim = black.alpha(0.30)
    /// The scrim used when Increase Contrast is on.
    static let hudScrimIncreased = black.alpha(0.45)
    /// The top gradient behind the utility controls.
    static let hudTopShade = black.alpha(0.62)
    /// The bottom gradient behind metadata and the timeline.
    static let hudBottomShade = black.alpha(0.84)
    /// The tint inside a clear Liquid Glass capsule.
    static let hudGlassTint = black.alpha(0.45)
    /// The tint inside a regular Liquid Glass transport disc.
    static let hudDiscGlassTint = black.alpha(0.55)
    /// The opaque backing under a transport disc before glass is applied.
    static let hudDiscBackground = ColorToken(nsColor: NSColor(white: 0.13, alpha: 0.9))
    /// A white border on a HUD control.
    static let hudControlBorder = white.alpha(0.8)
    /// The volume slider's played portion inside the HUD.
    static let hudVolumeFill = white.alpha(0.92)
    /// The volume slider's unplayed portion inside the HUD.
    static let hudVolumeTrack = white.alpha(0.22)
    /// The track behind a small progress bar over media.
    static let progressTrack = white.alpha(0.26)

    // MARK: Palette: Legacy asset colours

    /// The initial window's recent-file row.
    static let initialWindowLastFile = ColorToken(nsColor: .initialWindowLastFileBackground)
    /// The initial window's recent-file row on hover.
    static let initialWindowLastFileHover = ColorToken(nsColor: .initialWindowLastFileBackgroundHover)
    /// The initial window's recent-file row while pressed.
    static let initialWindowLastFilePressed = ColorToken(nsColor: .initialWindowLastFileBackgroundPressed)
    /// The beta channel label.
    static let initialWindowBetaLabel = ColorToken(nsColor: .initialWindowBetaLabel)
    /// The debug channel label.
    static let initialWindowDebugLabel = ColorToken(nsColor: .initialWindowDebugLabel)
    /// The nightly channel label.
    static let initialWindowNightlyLabel = ColorToken(nsColor: .initialWindowNightlyLabel)

    /// The main slider's knob.
    static let mainSliderKnob = ColorToken(nsColor: .mainSliderKnob)
    /// The main slider's knob while active.
    static let mainSliderKnobActive = ColorToken(nsColor: .mainSliderKnobActive)
    /// The main slider's played portion.
    static let mainSliderBarLeft = ColorToken(nsColor: .mainSliderBarLeft)
    /// The main slider's unplayed portion.
    static let mainSliderBarRight = ColorToken(nsColor: .mainSliderBarRight)
    /// The main slider's loop knob.
    static let mainSliderLoopKnob = ColorToken(nsColor: .mainSliderLoopKnob)

    /// The volume slider's played portion.
    static let volumeSliderBarLeft = ColorToken(nsColor: .volumeSliderBarLeft)
    /// The volume slider's unplayed portion.
    static let volumeSliderBarRight = ColorToken(nsColor: .volumeSliderBarRight)

    /// The sidebar container border.
    static let sidebarContainerBorder = ColorToken(nsColor: .sidebarContainerBorder)
    /// The sidebar tab button border.
    static let sidebarTabButtonBorder = ColorToken(nsColor: .sidebarTabBtnBorder)
    /// The sidebar table backing.
    static let sidebarTableBackground = ColorToken(nsColor: .sidebarTableBackground)
    /// An inactive sidebar tab's tint.
    static let sidebarTabTint = ColorToken(nsColor: .sidebarTabTint)
    /// The active sidebar tab's tint.
    static let sidebarTabTintActive = ColorToken(nsColor: .sidebarTabTintActive)

    /// The titlebar's bottom border.
    static let titleBarBorder = ColorToken(nsColor: .titleBarBorder)
    /// The crop box's fill.
    static let cropBoxFill = ColorToken(nsColor: .cropBoxFill)
    /// The playlist progress bar.
    static let playlistProgressBar = ColorToken(nsColor: .playlistProgressBar)

    // MARK: Palette: Legacy computed colours

    /// A key-record view at rest.
    static let keyRecordBackground = ColorToken(nsColor: .controlBackgroundColor.withSystemEffect(.disabled))
    /// An active key-record view.
    static let keyRecordBackgroundActive = ColorToken(nsColor: .controlBackgroundColor)
    /// The inspector watch table's backing.
    static let inspectorWatchBackground = ColorToken(nsColor: NSColor(red: 2.0 / 3, green: 2.0 / 3, blue: 2.0 / 3, alpha: 0.1))
    /// The inspector watch table's column header.
    static let inspectorWatchHeader = ColorToken(nsColor: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
    /// The pressed background of a preference tab.
    static let preferenceTabPressed = ColorToken(nsColor: .windowBackgroundColor.withSystemEffect(.pressed))
    /// The app name's gradient base in About.
    static let aboutGradient = ColorToken(nsColor: NSColor(white: 0.925, alpha: 1))
    /// The accent colour lightened for the playlist selection.
    static let accentBlend = ColorToken(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.2, of: .white) ?? .controlAccentColor)
    /// A translucent grey used by sidebars and selection pills.
    static let sidebarFillSubtle = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.1))
    /// A stronger translucent grey used by sidebars and selection pills.
    static let sidebarFill = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.15))
    /// The strongest translucent grey in the sidebar.
    static let sidebarFillStrong = ColorToken(nsColor: NSColor.gray.withAlphaComponent(0.2))
    /// A red-tinted permission warning box.
    static let permissionWarningFill = ColorToken(nsColor: NSColor.systemRed.withAlphaComponent(0.3))
    /// The legacy shadow under a sidebar tab.
    static let sidebarShadow = black.alpha(0.3)
    /// The legacy shadow under a floating panel.
    static let panelShadow = black.alpha(0.5)
    /// The guide overlay's shadow.
    static let guideShadow = black.alpha(0.5)
    /// The generic black shadow used by legacy AppKit views.
    static let shadow = black.alpha(0.5)
    /// The subtitle overlay's border.
    static let subtitleBorder = black
    /// The subtitle overlay's shadow.
    static let subtitleShadow = black
    /// Text on a selected toolbar segment.
    static let selectedSegmentText = white
    /// The separator inside a segmented control.
    static let segmentSeparator = white.alpha(0.8)
    /// The inspector's disabled row text.
    static let inspectorDisabledText = textDisabled
    /// The settings card's border.
    static let settingsCardBorder = black.alpha(0.08)
    /// The subtler border used by the settings page container.
    static let settingsCardBorderSubtle = black.alpha(0.05)
    /// The settings card's fill.
    static let settingsCardFill = black.alpha(0.02)
    /// A selected settings item.
    static let settingsSelection = ColorToken(nsColor: .highlightColor).alpha(0.1)
    /// A strongly selected settings item.
    static let settingsSelectionStrong = ColorToken(nsColor: .highlightColor).alpha(0.2)
    /// The screenshot preview's border.
    static let screenshotBorder = ColorToken(nsColor: .gridColor).alpha(0.6)
    /// A faint white overlay on a dark table.
    static let tableOverlay = white.alpha(0.05)
    /// A stroke on the Touch Bar preview.
    static let touchBarStroke = ColorToken(nsColor: .labelColor).alpha(0.4)
    /// The placeholder tile behind a missing plugin icon.
    static let placeholderFill = ColorToken(nsColor: .gray).alpha(0.2)
    /// A log entry at the error level.
    static let logError = ColorToken(nsColor: .systemRed)
    /// A log entry at the warning level.
    static let logWarning = ColorToken(nsColor: .systemOrange)
    /// A log entry at the debug or verbose level.
    static let logDebug = ColorToken(nsColor: .gray)
    /// A log entry at the information level.
    static let logInfo = ColorToken(nsColor: .systemBlue)
    /// A log string value.
    static let logString = ColorToken(nsColor: .systemBrown)
    /// A log boolean value.
    static let logBoolean = ColorToken(nsColor: .systemPurple)
    /// A neutral indicator glyph.
    static let indicatorNeutral = ColorToken(nsColor: NSColor(calibratedWhite: 0.5, alpha: 1))
    /// The thumbnail preview's border.
    static let thumbnailBorder = ColorToken(nsColor: NSColor(calibratedWhite: 0.6, alpha: 0.5))
    /// A log entry at the success level.
    static let logSuccess = ColorToken(nsColor: .systemGreen)
  }

  // MARK: Netflix ratings

  /// Netflix card annotations, rendered inside the third-party webpage.
  enum NetflixRatings {
    /// Shared badge typography, contrast, placement and focus treatment.
    static let css = """
      .uniplayer-imdb-card { position: relative !important; }
      .uniplayer-imdb-wrap { position: absolute !important; top: 0 !important; right: 0 !important; z-index: 5 !important; display: inline-flex !important; }
      .uniplayer-imdb-wrap > .uniplayer-imdb-rating { position: relative !important; }
      .uniplayer-imdb-wrap[data-layout="inline"] { position: relative !important; margin: 8px 0 !important; width: fit-content !important; }
      .uniplayer-imdb-edit { position: absolute !important; right: 100% !important; top: 0 !important; width: 28px !important; height: 32px !important; padding: 7px !important; border: 0 !important; border-radius: 6px 0 0 6px !important; color: #fff !important; background: #242424 !important; opacity: 0 !important; pointer-events: none !important; cursor: pointer !important; }
      .uniplayer-imdb-wrap:hover > .uniplayer-imdb-edit, .uniplayer-imdb-wrap:focus-within > .uniplayer-imdb-edit { opacity: 1 !important; pointer-events: auto !important; }
      .uniplayer-imdb-edit[hidden] { display: none !important; }
      .uniplayer-imdb-edit svg { width: 100% !important; height: 100% !important; }
      .uniplayer-imdb-edit:focus-visible { outline: 2px solid #fff !important; outline-offset: 2px !important; }
      .uniplayer-imdb-rating {
        position: absolute !important; right: 0 !important; top: 0 !important;
        bottom: auto !important; left: auto !important; z-index: 5 !important;
        display: inline-flex !important; align-items: center !important; gap: 7px !important;
        min-height: 32px !important; min-width: 118px !important; justify-content: center !important; box-sizing: border-box !important;
        padding: 5px 9px !important; margin: 0 !important;
        border: 0 !important; border-radius: 0 8px 0 8px !important;
        background: #e50914 !important; color: #fff !important;
        font: 700 14px/1.2 -apple-system, BlinkMacSystemFont, sans-serif !important;
        font-variant-numeric: tabular-nums !important; white-space: nowrap !important;
        cursor: pointer !important; box-shadow: 0 2px 6px rgba(0,0,0,.28) !important;
        opacity: 1 !important; text-decoration: none !important; letter-spacing: .1px !important;
      }
      .uniplayer-imdb-rating[data-state="unverified"] { background: #301316 !important; box-shadow: inset 0 0 0 1px rgba(255,255,255,.42), 0 2px 6px rgba(0,0,0,.28) !important; }
      .uniplayer-imdb-rating[data-state="loading"], .uniplayer-imdb-rating[data-state="unavailable"] { min-width: 58px !important; background: #242424 !important; color: #ccc !important; }
      .uniplayer-imdb-rating .rating-value { font: inherit !important; font-size: 16px !important; }
      .uniplayer-imdb-rating .rating-votes { font-size: 12px !important; font-weight: 500 !important; }
      .uniplayer-imdb-rating .rating-status { display: inline-flex !important; width: 15px !important; height: 17px !important; }
      .uniplayer-imdb-rating .rating-status svg { width: 100% !important; height: 100% !important; }
      .uniplayer-imdb-rating:focus-visible { outline: 2px solid #fff !important; outline-offset: 2px !important; }
      """
    /// A confirmed title match, using Netflix release year and format.
    static let verifiedIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 22" fill="none" aria-hidden="true"><path d="M10 1.5 17.5 4v6.2c0 4.5-3.2 7.6-7.5 10.3-4.3-2.7-7.5-5.8-7.5-10.3V4L10 1.5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="m6.5 10.5 2.4 2.4 4.7-5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    /// Compact correction action, revealed on hover or keyboard focus.
    static let editIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="m12.5 3.5 4 4M3 17l4.5-1L17 6.5a2.8 2.8 0 0 0-4-4L3.5 12 3 17Z" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    /// An unconfirmed or unavailable title match, distinct by shape as well as fill.
    static let unverifiedIcon = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 22" fill="none" aria-hidden="true"><path d="M10 1.5 17.5 4v6.2c0 4.5-3.2 7.6-7.5 10.3-4.3-2.7-7.5-5.8-7.5-10.3V4L10 1.5Z" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M7.8 8a2.2 2.2 0 0 1 4.4 0c0 1.8-2.2 1.7-2.2 3.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="10" cy="14.3" r=".9" fill="currentColor"/></svg>"#
  }

  // MARK: Typography

  /// The type ramp. Sizes that match standard AppKit controls derive from the
  /// platform's own constants so they track the system; product sizes are
  /// declared once here.
  enum Typography {

    // MARK: Typography: Library roles

    /// A hero's title.
    static let heroTitle = FontToken(size: 34, weight: .bold)
    /// A hero's supporting line.
    static let heroBody = FontToken(size: 15, weight: .regular)
    /// A page or section heading.
    static let sectionTitle = FontToken(size: 17, weight: .semibold)
    /// A page title above a grid.
    static let pageTitle = FontToken(size: 26, weight: .bold)
    /// Channel identity and connection-state symbol.
    static let channelStateIcon = FontToken(size: 48, weight: .regular)
    /// A card's title.
    static let cardTitle = FontToken(size: 13, weight: .semibold)
    /// A titlebar icon glyph, matching the reference app's toolbar symbols.
    static let titlebarIcon = FontToken(size: 16, weight: .regular)
    /// Body copy.
    static let body = FontToken(size: NSFont.systemFontSize, weight: .regular)
    /// A button's label.
    static let button = FontToken(size: NSFont.systemFontSize, weight: .medium)
    /// Emphasised body copy.
    static let bodyStrong = FontToken(size: NSFont.systemFontSize, weight: .bold)
    /// A bold caption.
    static let captionStrong = FontToken(size: NSFont.smallSystemFontSize, weight: .bold)
    /// A bold 12 pt label.
    static let size12Strong = FontToken(size: 12, weight: .bold)
    /// The menu's numeric font, sized by the system.
    static let menuNumeric = FontToken(size: 0, weight: .regular, family: .monospacedDigit)
    /// An 18 pt bold monospaced title.
    static let monoTitle = FontToken(size: 18, weight: .bold, family: .monospaced)
    /// The small developer badge, which is slightly smaller than a caption.
    static let devBadge = FontToken(size: 10, weight: .bold)
    /// The URL field in the Open URL sheet.
    static let urlField = FontToken(size: 20, weight: .regular)
    /// The loading label in the Open URL sheet.
    static let loading = FontToken(size: 16, weight: .regular)
    /// The recorded-key display.
    static let keyRecord = FontToken(size: 22, weight: .regular, family: .monospaced)
    /// A code sample shown in settings.
    static let codeSample = FontToken(size: 12, weight: .regular, family: .monospaced)
    /// The font-picker preview.
    static let preview = FontToken(size: 24, weight: .regular)

    /// A system font at a dynamic size, for text that scales with user settings.
    static func systemFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
      .systemFont(ofSize: size, weight: weight)
    }

    /// A monospaced font at a dynamic size.
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
      .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// A tabular-figure font at a dynamic size.
    static func numericFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
      .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// A font chosen by the user, at a tokenised size.
    static func namedFont(name: String, size: CGFloat) -> NSFont {
      NSFont(name: name, size: size) ?? systemFont(size: size)
    }

    /// A font built from a descriptor at a tokenised size.
    static func descriptorFont(_ descriptor: NSFontDescriptor, size: CGFloat) -> NSFont {
      NSFont(descriptor: descriptor, size: size) ?? systemFont(size: size)
    }
    /// The smallest supporting line.
    static let caption = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)
    /// The search field's text.
    static let searchField = FontToken(size: 15, weight: .regular)

    // MARK: Typography: App roles

    /// The app name in the initial window.
    static let appTitle = FontToken(size: 20, weight: .bold)
    /// The app name in About.
    static let aboutTitle = FontToken(size: 24, weight: .light)
    /// A dialog or detail title.
    static let detailTitle = FontToken(size: 18, weight: .regular)
    /// An emphasised dialog title.
    static let detailTitleStrong = FontToken(size: 18, weight: .semibold)
    /// A settings page title.
    static let settingsTitle = FontToken(size: 14, weight: .bold)
    /// A settings row title.
    static let settingsRowTitle = FontToken(size: 15, weight: .regular)
    /// A sidebar section title.
    static let sidebarSection = FontToken(size: 12, weight: .bold)
    /// A sidebar item label.
    static let sidebarItem = FontToken(size: 11, weight: .regular)
    /// A small sidebar label.
    static let sidebarCaption = FontToken(size: 10, weight: .regular)
    /// A tag or badge.
    static let badge = FontToken(size: 10, weight: .regular)
    /// A small badge.
    static let badgeStrong = FontToken(size: 10, weight: .bold)

    // MARK: Typography: Numeric and monospaced

    /// Tabular figures for a time or duration.
    static let numeric = FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospacedDigit)
    /// Tabular figures at body size.
    static let numericBody = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospacedDigit)
    /// A bold time display.
    static let numericTitle = FontToken(size: 18, weight: .bold, family: .monospacedDigit)
    /// A monospaced body, for logs and code.
    static let mono = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)
    /// A monospaced caption.
    static let monoCaption = FontToken(size: NSFont.smallSystemFontSize, weight: .regular, family: .monospaced)
    /// A monospaced key label.
    static let monoKey = FontToken(size: NSFont.systemFontSize, weight: .regular, family: .monospaced)

    // MARK: Typography: Menu and control variants

    /// The system menu font.
    static let menu = FontToken(size: 0, weight: .regular, family: .system)
    /// The system message font size.
    static let message = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)
    /// The system label font size.
    static let label = FontToken(size: NSFont.systemFontSize, weight: .regular)

    // MARK: Typography: Raw ramp

    /// 9 pt, for the smallest labels that predate the role ramp.
    static let size9 = FontToken(size: 10, weight: .regular)
    /// 10 pt supporting text.
    static let size10 = FontToken(size: 10, weight: .regular)
    /// 11 pt system text.
    static let size11 = FontToken(size: NSFont.smallSystemFontSize, weight: .regular)
    /// 12 pt text.
    static let size12 = FontToken(size: 12, weight: .regular)
    /// 13 pt system text.
    static let size13 = body
    /// 13.5 pt, used by toolbar symbols.
    static let size13_5 = FontToken(size: 13.5, weight: .regular)
    /// 14 pt text.
    static let size14 = FontToken(size: 14, weight: .regular)
    /// 15 pt text.
    static let size15 = searchField
    /// 16 pt text.
    static let size16 = FontToken(size: 16, weight: .regular)
    /// 18 pt text.
    static let size18 = detailTitle
    /// 20 pt text.
    static let size20 = FontToken(size: 20, weight: .regular)
    /// 24 pt text.
    static let size24 = aboutTitle
    /// 26 pt text.
    static let size26 = pageTitle
    /// 30 pt text.
    static let size30 = FontToken(size: 30, weight: .regular)
    /// 34 pt text.
    static let size34 = heroTitle
    /// 42 pt text.
    static let size42 = FontToken(size: 42, weight: .light)
  }

  // MARK: Spacing

  /// Spacing and inset values. The numeric names are the scale; the named
  /// aliases give the recurring roles a meaning.
  /// Torrent action and native inspection surface; isolated from window chrome.
  enum Torrent {
    static let sheetWidth: CGFloat = 600
    static let sheetHeight: CGFloat = 620
    static let icon = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' aria-hidden='true'><path d='M9 6v12l10-6z' fill='currentColor'/><path d='M6 4H3v16h3' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round'/></svg>"
    static let css = """
    .uniplayer-torrent-action {display:inline-flex!important;align-items:center!important;justify-content:center!important;vertical-align:middle!important;width:32px!important;height:32px!important;margin:4px 6px!important;border:1px solid #ffffff30!important;border-radius:9px!important;background:#24262cf5!important;color:#f4c65c!important;cursor:pointer!important;box-shadow:0 2px 6px #0005!important;line-height:1!important;padding:5px!important;}
    .uniplayer-torrent-action:hover {background:#3b3d44!important;color:#ffe19b!important;}
    .uniplayer-torrent-action:focus-visible {outline:3px solid #71aaff!important;outline-offset:2px!important;}
    .uniplayer-torrent-action svg {width:20px!important;height:20px!important;pointer-events:none!important;}
    """
  }

  enum Space {
    /// 0 pt.
    static let n0: CGFloat = 0
    /// 1 pt.
    static let n1: CGFloat = 1
    /// 2 pt.
    static let n2: CGFloat = 2
    /// 2.5 pt.
    static let n2_5: CGFloat = 2.5
    /// 3 pt.
    static let n3: CGFloat = 3
    /// 4 pt.
    static let n4: CGFloat = 4
    /// 5 pt.
    static let n5: CGFloat = 5
    /// 6 pt.
    static let n6: CGFloat = 6
    /// 8 pt.
    static let n8: CGFloat = 8
    /// 9 pt.
    static let n9: CGFloat = 9
    /// 10 pt.
    static let n10: CGFloat = 10
    /// 11 pt.
    static let n11: CGFloat = 11
    /// 12 pt.
    static let n12: CGFloat = 12
    /// 14 pt.
    static let n14: CGFloat = 14
    /// 15 pt.
    static let n15: CGFloat = 15
    /// 16 pt.
    static let n16: CGFloat = 16
    /// 17 pt.
    static let n17: CGFloat = 17
    /// 18 pt.
    static let n18: CGFloat = 18
    /// 19 pt.
    static let n19: CGFloat = 19
    /// 20 pt.
    static let n20: CGFloat = 20
    /// 24 pt.
    static let n24: CGFloat = 24
    /// 25 pt.
    static let n25: CGFloat = 25
    /// 26 pt.
    static let n26: CGFloat = 26
    /// 28 pt.
    static let n28: CGFloat = 28
    /// 30 pt.
    static let n30: CGFloat = 30
    /// 32 pt.
    static let n32: CGFloat = 32
    /// 36 pt.
    static let n36: CGFloat = 36
    /// 45 pt.
    static let n45: CGFloat = 45
    /// 46 pt.
    static let n46: CGFloat = 46
    /// 40 pt.
    static let n40: CGFloat = 40
    /// 48 pt.
    static let n48: CGFloat = 48
    /// 52 pt.
    static let n52: CGFloat = 52
    /// 60 pt.
    static let n60: CGFloat = 60
    /// 64 pt.
    static let n64: CGFloat = 64
    /// 68 pt.
    static let n68: CGFloat = 68
    /// 80 pt.
    static let n80: CGFloat = 80
    /// 84 pt.
    static let n84: CGFloat = 84
    /// 86 pt, the titlebar's leading inset that clears the traffic lights.
    static let n86: CGFloat = 86
    /// 200 pt.
    static let n200: CGFloat = 200
    /// 260 pt.
    static let n260: CGFloat = 260
    /// 300 pt.
    static let n300: CGFloat = 300

    // MARK: Spacing: Roles

    /// The gap between related controls.
    static let controlGap = n8
    /// The gap between rows in a stack.
    static let rowGap = n12
    /// The gap between a title and its shelf.
    static let titleGap = n12
    /// The gap between sections.
    static let sectionGap = n32
    /// The page's horizontal margin.
    static let pageMargin = n40
    /// The page's top margin.
    static let pageTop = n24
    /// The page's bottom margin.
    static let pageBottom = n48
  }

  // MARK: Radius

  /// Corner radii.
  enum Radius {
    /// 0 pt.
    static let n0: CGFloat = 0
    /// 1 pt.
    static let n1: CGFloat = 1
    /// 1.5 pt.
    static let n1_5: CGFloat = 1.5
    /// 2 pt.
    static let n2: CGFloat = 2
    /// 2.5 pt.
    static let n2_5: CGFloat = 2.5
    /// 3 pt.
    static let n3: CGFloat = 3
    /// 4 pt.
    static let n4: CGFloat = 4
    /// 6 pt.
    static let n6: CGFloat = 6
    /// 8 pt.
    static let n8: CGFloat = 8
    /// 10 pt.
    static let n10: CGFloat = 10
    /// 11 pt.
    static let n11: CGFloat = 11
    /// 12 pt.
    static let n12: CGFloat = 12
    /// 14 pt.
    static let n14: CGFloat = 14
    /// 15 pt.
    static let n15: CGFloat = 15
    /// 16 pt.
    static let n16: CGFloat = 16
    /// 18 pt.
    static let n18: CGFloat = 18

    // MARK: Radius: Roles

    /// A card's corner.
    static let card = n10
    /// A hero's corner.
    static let hero = n14
    /// A HUD capsule's corner.
    static let capsule = n15
    /// The HUD timeline's corner.
    static let timeline = n14
    /// A settings card's corner, which follows the platform's control shape.
    static let settingsCard = n12
    /// A small control's corner.
    static let control = n4
    /// A sidebar container's corner.
    static let sidebarContainer = n8
    /// A floating panel's corner.
    static let panel = n10
  }

  // MARK: Stroke

  /// Line and border widths.
  enum Stroke {
    /// No stroke.
    static let none: CGFloat = 0
    /// A hairline.
    static let hairline: CGFloat = 1
    /// 0.4 pt, the legacy slider outline.
    static let n0_4: CGFloat = 0.4
    /// 1.5 pt.
    static let n1_5: CGFloat = 1.5
    /// 4 pt.
    static let n4: CGFloat = 4
    /// A prominent border.
    static let strong: CGFloat = 2
    /// A focus ring.
    static let focus: CGFloat = 3
  }

  // MARK: Blur

  /// Blur radii, used by shadows and soft edges.
  enum Blur {
    /// 1 pt.
    static let n1: CGFloat = 1
    /// 2 pt.
    static let n2: CGFloat = 2
    /// 4 pt.
    static let n4: CGFloat = 4
    /// 6 pt.
    static let n6: CGFloat = 6
    /// 8 pt.
    static let n8: CGFloat = 8
    /// 10 pt.
    static let n10: CGFloat = 10
    /// 12 pt.
    static let n12: CGFloat = 12
    /// 13 pt.
    static let n13: CGFloat = 13
    /// 14 pt.
    static let n14: CGFloat = 14
    /// 24 pt.
    static let n24: CGFloat = 24
  }

  // MARK: Opacity

  /// Alpha values used for scrims, borders, tints and disabled states.
  enum Opacity {
    /// 0.
    static let n00: CGFloat = 0
    /// 0.02.
    static let n02: CGFloat = 0.02
    /// 0.05.
    static let n05: CGFloat = 0.05
    /// 0.08.
    static let n08: CGFloat = 0.08
    /// 0.10.
    static let n10: CGFloat = 0.10
    /// 0.12.
    static let n12: CGFloat = 0.12
    /// 0.15.
    static let n15: CGFloat = 0.15
    /// 0.18.
    static let n18: CGFloat = 0.18
    /// 0.20.
    static let n20: CGFloat = 0.20
    /// 0.22.
    static let n22: CGFloat = 0.22
    /// 0.26.
    static let n26: CGFloat = 0.26
    /// 0.28.
    static let n28: CGFloat = 0.28
    /// 0.30.
    static let n30: CGFloat = 0.30
    /// 0.34.
    static let n34: CGFloat = 0.34
    /// 0.35.
    static let n35: CGFloat = 0.35
    /// 0.40.
    static let n40: CGFloat = 0.40
    /// 0.45.
    static let n45: CGFloat = 0.45
    /// 0.50.
    static let n50: CGFloat = 0.50
    /// 0.55.
    static let n55: CGFloat = 0.55
    /// 0.60.
    static let n60: CGFloat = 0.60
    /// 0.62.
    static let n62: CGFloat = 0.62
    /// 0.65.
    static let n65: CGFloat = 0.65
    /// 0.68.
    static let n68: CGFloat = 0.68
    /// 0.72.
    static let n72: CGFloat = 0.72
    /// 0.78.
    static let n78: CGFloat = 0.78
    /// 0.80.
    static let n80: CGFloat = 0.80
    /// 0.84.
    static let n84: CGFloat = 0.84
    /// 0.88.
    static let n88: CGFloat = 0.88
    /// 0.90.
    static let n90: CGFloat = 0.90
    /// 0.92.
    static let n92: CGFloat = 0.92
    /// 0.96.
    static let n96: CGFloat = 0.96
    /// 0.98.
    static let n98: CGFloat = 0.98

    /// Fully visible content.
    static let opaque: CGFloat = 1
    /// A disabled control's opacity.
    static let disabled = n40
    /// A resting border.
    static let border = n08
    /// A hover border.
    static let borderHover = n28
    /// The HUD's scrim.
    static let scrim = n30
  }

  // MARK: Sizes

  /// Component and control dimensions. Sizes that belong to one component are
  /// declared beside that component's tokens; the numeric scale covers the
  /// legacy surfaces.
  enum Size {
    /// 0 pt.
    static let n0: CGFloat = 0
    /// 1 pt.
    static let n1: CGFloat = 1
    /// 3 pt.
    static let n3: CGFloat = 3
    /// 0.75 pt.
    static let n0_75: CGFloat = 0.75
    /// 10 pt.
    static let n10: CGFloat = 10
    /// 11 pt.
    static let n11: CGFloat = 11
    /// 12 pt.
    static let n12: CGFloat = 12
    /// 13 pt.
    static let n13: CGFloat = 13
    /// 14 pt.
    static let n14: CGFloat = 14
    /// 24 pt.
    static let n24: CGFloat = 24
    /// 25 pt.
    static let n25: CGFloat = 25
    /// 25 pt.
    static let n2_5: CGFloat = 2.5
    /// 26 pt.
    static let n26: CGFloat = 26
    /// 28 pt.
    static let n28: CGFloat = 28
    /// 30 pt.
    static let n30: CGFloat = 30
    /// 31 pt.
    static let n31: CGFloat = 31
    /// 36 pt.
    static let n36: CGFloat = 36
    /// 37 pt.
    static let n37: CGFloat = 37
    /// 42 pt.
    static let n42: CGFloat = 42
    /// 48 pt.
    static let n48: CGFloat = 48
    /// 52 pt.
    static let n52: CGFloat = 52
    /// 50 pt.
    static let n50: CGFloat = 50
    /// 60 pt.
    static let n60: CGFloat = 60
    /// 64 pt.
    static let n64: CGFloat = 64
    /// 120 pt.
    static let n120: CGFloat = 120
    /// 200 pt.
    static let n200: CGFloat = 200
    /// 285 pt.
    static let n285: CGFloat = 285
    /// 300 pt.
    static let n300: CGFloat = 300
    /// 400 pt.
    static let n400: CGFloat = 400
    /// 480 pt.
    static let n480: CGFloat = 480
    /// 500 pt.
    static let n500: CGFloat = 500
    /// 600 pt.
    static let n600: CGFloat = 600
    /// 640 pt.
    static let n640: CGFloat = 640
    /// 800 pt.
    static let n800: CGFloat = 800
    /// 2000 pt.
    static let n2000: CGFloat = 2000
    /// 0.5 pt.
    static let n0_5: CGFloat = 0.5
    /// 67 pt.
    static let n67: CGFloat = 67
    /// 96 pt.
    static let n96: CGFloat = 96
    /// 100 pt.
    static let n100: CGFloat = 100
    /// 140 pt.
    static let n140: CGFloat = 140
    /// 146 pt.
    static let n146: CGFloat = 146
    /// 180 pt.
    static let n180: CGFloat = 180
    /// 220 pt.
    static let n220: CGFloat = 220
    /// 240 pt.
    static let n240: CGFloat = 240
    /// 260 pt.
    static let n260: CGFloat = 260
    /// 340 pt.
    static let n340: CGFloat = 340
    /// 360 pt.
    static let n360: CGFloat = 360
    /// 420 pt.
    static let n420: CGFloat = 420
    /// 430 pt.
    static let n430: CGFloat = 430

    /// 2 pt.
    static let n2: CGFloat = 2
    /// 4 pt.
    static let n4: CGFloat = 4
    /// 8 pt.
    static let n8: CGFloat = 8
    /// 15 pt.
    static let n15: CGFloat = 15
    /// 16 pt.
    static let n16: CGFloat = 16
    /// 17 pt.
    static let n17: CGFloat = 17
    /// 18 pt.
    static let n18: CGFloat = 18
    /// 19 pt.
    static let n19: CGFloat = 19
    /// 20 pt.
    static let n20: CGFloat = 20
    /// 22 pt.
    static let n22: CGFloat = 22
    /// 32 pt.
    static let n32: CGFloat = 32
    /// 45 pt.
    static let n45: CGFloat = 45
    /// 46 pt.
    static let n46: CGFloat = 46
    /// 40 pt.
    static let n40: CGFloat = 40
    /// 70 pt.
    static let n70: CGFloat = 70
    /// 80 pt.
    static let n80: CGFloat = 80
    /// 105.6 pt.
    static let n105_6: CGFloat = 105.6
    /// 108 pt.
    static let n108: CGFloat = 108
    /// 150 pt.
    static let n150: CGFloat = 150
    /// 59.4 pt.
    static let n59_4: CGFloat = 59.4

    /// 440 pt.
    static let n440: CGFloat = 440
    /// 450 pt.
    static let n450: CGFloat = 450
    /// 520 pt.
    static let n520: CGFloat = 520
    /// 560 pt.
    static let n560: CGFloat = 560
    /// 54 pt.
    static let n54: CGFloat = 54
    /// 82 pt.
    static let n82: CGFloat = 82
    /// 90 pt.
    static let n90: CGFloat = 90
    /// 98 pt.
    static let n98: CGFloat = 98
    /// 68 pt.
    static let n68: CGFloat = 68

    // MARK: Sizes: Roles

    /// The library window's default size.
    static let window = NSSize(width: 1220, height: 720)
    /// The library window's minimum size.
    static let minimumWindow = NSSize(width: 900, height: 560)
    /// The library sidebar's ideal width.
    static let sidebarWidth: CGFloat = 220
    /// The titlebar's height.
    static let titlebarHeight: CGFloat = 32
    /// The settings sidebar's width.
    static let settingsSidebarWidth: CGFloat = 180
    /// The settings content's width.
    static let settingsContentWidth: CGFloat = 340
    /// The settings window's width.
    static let settingsWindowWidth: CGFloat = 650
    /// A numeric input's width.
    static let inputWidth: CGFloat = 48
    /// A numeric input's height.
    static let inputHeight: CGFloat = 25
    /// A text input's width.
    static let textInputWidth: CGFloat = 64
    /// A colour well's height.
    static let colorWellHeight: CGFloat = 24
    /// A colour well's fallback width.
    static let colorWellWidth: CGFloat = 30
    /// The library card's width.
    static let cardWidth: CGFloat = 215
    /// The library card's height.
    static let cardHeight: CGFloat = 151
    /// The minimum adaptive grid item.
    static let gridMinimum: CGFloat = 200
    /// The maximum adaptive grid item.
    static let gridMaximum: CGFloat = 280
    /// Decoded width of a library poster frame: the widest grid card at 3×
    /// backing, so artwork stays sharp when a card grows or a display scales.
    static let posterFrameWidth: CGFloat = 640
    /// The library search field's width.
    static let searchFieldWidth: CGFloat = 420
    /// The floating OSC's width.
    static let oscFloatingWidth: CGFloat = 460
    /// The settings screenshot preview's width.
    static let imagePreviewWidth: CGFloat = 480 * 0.22
    /// The settings screenshot preview's height.
    static let imagePreviewHeight: CGFloat = 270 * 0.22
    /// The detail page's progress width.
    static let progressWidth: CGFloat = 180
    /// The empty state's message width.
    static let emptyStateWidth: CGFloat = 360
  }

  // MARK: Icons

  /// SF Symbol point sizes.
  enum Icon {
    /// 10 pt.
    static let n10: CGFloat = 10
    /// 11 pt.
    static let n11: CGFloat = 11
    /// 12 pt.
    static let n12: CGFloat = 12
    /// 13 pt.
    static let n13: CGFloat = 13
    /// 13.5 pt.
    static let n13_5: CGFloat = 13.5
    /// 14 pt.
    static let n14: CGFloat = 14
    /// 15 pt.
    static let n15: CGFloat = 15
    /// 16 pt.
    static let n16: CGFloat = 16
    /// 17 pt.
    static let n17: CGFloat = 17
    /// 18 pt.
    static let n18: CGFloat = 18
    /// 19 pt.
    static let n19: CGFloat = 19
    /// 20 pt.
    static let n20: CGFloat = 20
    /// 24 pt.
    static let n24: CGFloat = 24
    /// 25 pt.
    static let n25: CGFloat = 25
    /// 25 pt.
    static let n2_5: CGFloat = 2.5
    /// 26 pt.
    static let n26: CGFloat = 26
    /// 28 pt.
    static let n28: CGFloat = 28
    /// 30 pt.
    static let n30: CGFloat = 30
    /// 34 pt.
    static let n34: CGFloat = 34
    /// 42 pt.
    static let n42: CGFloat = 42
    /// 68 pt.
    static let n68: CGFloat = 68
  }

  // MARK: Motion

  /// Animation durations and curves.
  enum Motion {
    /// No animation.
    static let none = MotionToken(duration: 0)
    /// 0.1 seconds.
    static let n10 = MotionToken(duration: 0.1, curve: .easeOut)
    /// 0.16 seconds; the library's hover and focus motion.
    static let hover = MotionToken(duration: 0.16, curve: .easeOut)
    /// 0.2 seconds.
    static let n20 = MotionToken(duration: 0.2, curve: .easeOut)
    /// 0.24 seconds.
    static let n24 = MotionToken(duration: 0.24, curve: .easeIn)
    /// 0.25 seconds.
    static let n25 = MotionToken(duration: 0.25, curve: .easeInOut)
    /// 0.3 seconds.
    static let n30 = MotionToken(duration: 0.3, curve: .easeOut)
    /// 0.5 seconds.
    static let n50 = MotionToken(duration: 0.5, curve: .easeOut)
    /// The caret blink interval.
    static let caretBlink: TimeInterval = 1.0
    /// The slowest repeating UI pulse.
    static let pulse: TimeInterval = 1.5

    /// The standard window-resize animation.
    static let window = n25
    /// The SwiftUI animation for a token, honouring both Reduce Motion and the
    /// app's own animation preference.
    static func swiftUI(_ token: MotionToken, reduceMotion: Bool) -> Animation? {
      if reduceMotion || Preference.bool(for: .disableAnimations) {
        return nil
      }
      return token.animation
    }

    /// The standard HUD fade.
    static let hud = n25
    /// The standard sidebar transition.
    static let sidebar = n24
    /// The standard settings transition.
    static let settings = n25
  }

  // MARK: Materials

  /// Materials. A visual-effect token carries its blending mode and state so a
  /// view cannot pair a material with an incompatible configuration.
  enum Material {
    struct VisualEffect {
      let material: NSVisualEffectView.Material
      let blending: NSVisualEffectView.BlendingMode
      let state: NSVisualEffectView.State
    }

    struct Glass {
      let style: NSGlassEffectView.Style
      let tint: ColorToken?
      let interactive: Bool
    }

    /// A popover-style within-window material.
    static let popover = VisualEffect(material: .popover, blending: .withinWindow, state: .active)
    /// A sidebar material.
    static let sidebar = VisualEffect(material: .sidebar, blending: .withinWindow, state: .active)
    /// Library sidebar vibrancy, tracking the window's active state.
    static let librarySidebar = VisualEffect(material: .sidebar, blending: .behindWindow, state: .followsWindowActiveState)
    /// A titlebar material.
    static let titlebar = VisualEffect(material: .titlebar, blending: .withinWindow, state: .active)
    /// A window-background material behind the content.
    static let underWindowBackground = VisualEffect(material: .underWindowBackground, blending: .behindWindow, state: .active)
    /// A window-background material for footers.
    static let windowBackground = VisualEffect(material: .windowBackground, blending: .withinWindow, state: .active)

    /// The clear Liquid Glass group used by the HUD's utility capsules.
    static let glassCapsule = Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)
    /// The regular Liquid Glass transport disc.
    static let glassTransport = Glass(style: .regular, tint: Palette.hudDiscGlassTint, interactive: false)
    /// The clear Liquid Glass timeline capsule.
    static let glassTimeline = Glass(style: .clear, tint: Palette.hudGlassTint, interactive: true)
    /// The opaque fallback used when Liquid Glass is unavailable.
    static let glassFallback = VisualEffect(material: .popover, blending: .withinWindow, state: .active)
  }

  // MARK: Shadows

  /// Shadows.
  enum Shadow {
    /// A card's resting shadow.
    static let card = ShadowToken(color: Palette.black.alpha(Opacity.n22), radius: Blur.n12, offset: CGSize(width: 0, height: 5))
    /// A card's hover shadow.
    static let cardHover = ShadowToken(color: Palette.black.alpha(Opacity.n28), radius: Blur.n14, offset: CGSize(width: 0, height: 6))
    /// A hero's shadow.
    static let hero = ShadowToken(color: Palette.black.alpha(Opacity.n35), radius: Blur.n24, offset: CGSize(width: 0, height: 12))
    /// A small icon shadow.
    static let icon = ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Blur.n2, offset: CGSize(width: 0, height: 1))
    /// A floating panel's shadow.
    static let panel = ShadowToken(color: Palette.black.alpha(Opacity.n50), radius: Blur.n4, offset: CGSize(width: 0, height: 0))
    /// The titlebar text's shadow.
    static let titlebarText = ShadowToken(color: Palette.black, radius: Blur.n2, offset: .zero)
  }

  // MARK: Library

  /// Library-specific geometry that is not part of the global scale.
  enum Library {
    /// Minimum width of the central video or webpage, excluding docked panes.
    static let contentMinimumWidth: CGFloat = 640
    /// Initial width of the outward-opening library sidebar.
    static let outwardSidebarWidth: CGFloat = 280
    /// Smallest remembered outward sidebar width.
    static let outwardSidebarMinimum: CGFloat = 240
    /// Largest remembered outward sidebar width.
    static let outwardSidebarMaximum: CGFloat = 420
    /// Transparent top strip reserved for window dragging and titlebar controls.
    static let titlebarHeight: CGFloat = 52
    /// Readable width of the channel connection and recovery state.
    static let channelStateMaximumWidth: CGFloat = 420
    /// Media overlays use dark control rendering against the video surface.
    static let mediaOverlayColorScheme: ColorScheme = .dark
    /// Maximum width of floating playback transport.
    static let transportMaximumWidth: CGFloat = 720
    /// Individual glass playback button diameter.
    static let glassControlSize: CGFloat = 36
    /// Draggable pane separator hit width.
    static let paneResizeWidth: CGFloat = 8
    /// Diameter of the inline player's primary transport control.
    static let playControlSize: CGFloat = 44
    /// Maximum height of the Home overview artwork.
    static let heroMaximumHeight: CGFloat = 280
    /// The space reserved around a viewport-bounded player.
    static let playerReservedHeight: CGFloat = 240
    /// Minimum useful inline media height.
    static let playerMinimumHeight: CGFloat = 150
    /// Minimum detail width before hiding the sidebar beside an inspector.
    static let detailMinimumWidth: CGFloat = 520
    /// Width at which the inspector needs the sidebar space.
    static let inspectorCollapseWidth: CGFloat = 1160
    /// Height of the compact list thumbnail.
    static let listThumbnailHeight: CGFloat = 48
    /// Width of the compact list thumbnail.
    static let listThumbnailWidth: CGFloat = 84
    /// Opaque media control backing for stable contrast.
    static let transportBacking = ColorToken(nsColor: NSColor(white: 0.10, alpha: 1))

    /// The vertical gap inside a card.
    static let cardSpacing: CGFloat = Space.n8
    /// The padding inside a card.
    static let cardPadding: CGFloat = Space.n12
    /// The gap between cards.
    static let cardGap: CGFloat = Space.n20
    /// The gap inside a shelf.
    static let shelfSpacing: CGFloat = Space.n12
    /// The gap between a shelf's title and its content.
    static let shelfHeaderSpacing: CGFloat = Space.n12
    /// The gap inside the hero's text block.
    static let heroSpacing: CGFloat = Space.n10
    /// The hero's inner padding.
    static let heroPadding: CGFloat = Space.n32
    /// The hero button's horizontal padding.
    static let heroButtonHorizontal: CGFloat = Space.n18
    /// The hero button's vertical padding.
    static let heroButtonVertical: CGFloat = Space.n9
    /// The focus ring's outset.
    static let focusRingOutset: CGFloat = Space.n3
    /// The grid's row gap.
    static let gridRowGap: CGFloat = Space.n24
    /// The sidebar's minimum width.
    static let sidebarMinimum: CGFloat = Size.n200
    /// The sidebar's maximum width.
    static let sidebarMaximum: CGFloat = Size.n260
    /// The sidebar version label's inset.
    static let sidebarVersionInset: CGFloat = Space.n16
    /// The sidebar version label's bottom inset.
    static let sidebarVersionBottom: CGFloat = Space.n10
    /// The empty state's minimum height.
    static let emptyStateMinimum: CGFloat = Size.n260
    /// The grid page's empty state minimum height.
    static let gridEmptyStateMinimum: CGFloat = Size.n300
    /// The search field's corner.
    static let searchCorner = Radius.n10
    /// The search field's horizontal padding.
    static let searchHorizontal: CGFloat = Space.n14
    /// The search field's vertical padding.
    static let searchVertical: CGFloat = Space.n10
    /// The search field's top margin.
    static let searchTop: CGFloat = Space.n32
    /// The drop overlay's corner.
    static let dropCorner = Radius.n18
    /// The drop overlay's dash pattern.
    static let dropDash: [CGFloat] = [Space.n8, Space.n6]
    /// The drop overlay's padding.
    static let dropPadding: CGFloat = Space.n24
    /// The drop overlay's glyph size.
    static let dropGlyph = Icon.n30
    /// The top half of a generated placeholder.
    static func placeholderTop(hue: Double) -> Color {
      Color(hue: hue, saturation: placeholderSaturationTop, brightness: placeholderBrightnessTop)
    }
    /// The bottom half of a generated placeholder.
    static func placeholderBottom(hue: Double) -> Color {
      Color(hue: hue, saturation: placeholderSaturationBottom, brightness: placeholderBrightnessBottom)
    }
    /// The placeholder art glyph size.
    static let placeholderGlyph = Icon.n34
    /// The empty-state glyph size.
    static let emptyStateGlyph = Icon.n42
    /// The small progress bar's height.
    static let progressHeight: CGFloat = Space.n3
    /// The placeholder art's top saturation.
    static let placeholderSaturationTop: CGFloat = 0.42
    /// The placeholder art's top brightness.
    static let placeholderBrightnessTop: CGFloat = 0.34
    /// The placeholder art's bottom saturation.
    static let placeholderSaturationBottom: CGFloat = 0.50
    /// The placeholder art's bottom brightness.
    static let placeholderBrightnessBottom: CGFloat = 0.18
    /// The Continue Watching card's hover scale.
    static let hoverScale: CGFloat = 1.02
    /// The library card's hover scale.
    static let cardHoverScale: CGFloat = 1.015
  }

  // MARK: Inspector

  /// The AI inspector's column widths.
  enum Inspector {
    /// Caps recovery content so the assistant composer remains reachable.
    static let errorBannerMaximumHeight: CGFloat = 240
    /// Bounds long provider diagnostics inside the recovery banner.
    static let errorDetailsMaximumHeight: CGFloat = 100
    /// Height reserved for the scrollable attachment preview.
    static let contextPreviewHeight: CGFloat = 180
    /// The narrowest useful transcript column.
    static let minimumWidth: CGFloat = Size.n260
    /// The default column width beside a 16:9 surface.
    static let idealWidth: CGFloat = Size.n360
    /// The widest the column may grow before the video shrinks too far.
    static let maximumWidth: CGFloat = Size.n420
  }

  // MARK: Player HUD

  /// Player HUD geometry. These values come from the ledger's 1220×610 player
  /// and are measured in points at 1×.
  enum HUD {
    /// The utility capsule's horizontal padding.
    static let capsuleHorizontal: CGFloat = Space.n10
    /// The utility capsule's vertical padding.
    static let capsuleVertical: CGFloat = Space.n5
    /// The utility capsule's corner.
    static let capsuleCorner = Radius.capsule
    /// The metadata block's gap.
    static let metadataSpacing: CGFloat = Space.n2
    /// The transport stack's gap.
    static let controlSpacing: CGFloat = Space.n8
    /// The top controls' margin.
    static let topMargin: CGFloat = Space.n24
    /// The top controls' leading margin when the window is not full screen.
    static let topLeadingWindow: CGFloat = Space.n84
    /// The top controls' leading margin in full screen.
    static let topLeadingFullScreen: CGFloat = Space.n24
    /// The bottom controls' horizontal margin.
    static let bottomMargin: CGFloat = Space.n40
    /// The metadata's gap above the timeline.
    static let metadataBottomGap: CGFloat = Space.n14
    /// The gap between the metadata and the trailing controls.
    static let metadataTrailingGap: CGFloat = Space.n16
    /// The timeline's bottom margin.
    static let timelineBottom: CGFloat = Space.n28
    /// The timeline's height.
    static let timelineHeight: CGFloat = Space.n28
    /// The timeline glass's corner.
    static let timelineCorner = Radius.timeline
    /// The transport's vertical offset.
    static let transportOffset: CGFloat = Space.n24
    /// The top shade's maximum height.
    static let topShadeHeight: CGFloat = Size.n140
    /// The top shade's share of the window height.
    static let topShadeFraction: CGFloat = 0.3
    /// The bottom shade's maximum height.
    static let bottomShadeHeight: CGFloat = Size.n220
    /// The bottom shade's share of the window height.
    static let bottomShadeFraction: CGFloat = 0.45
    /// The play disc's diameter.
    static let playDisc: CGFloat = Size.n96
    /// The skip disc's diameter.
    static let skipDisc: CGFloat = Size.n64
    /// The play/pause symbol's point size.
    static let playPauseSymbol: CGFloat = Size.n48
    /// The skip symbol's point size.
    static let skipSymbol: CGFloat = Size.n30
    /// The transport's size when the OSC is docked.
    static let dockedTransport: CGFloat = Size.n24
    /// The gap inside a utility capsule.
    static let capsuleSpacing: CGFloat = Space.n10
    /// The gap inside the volume capsule.
    static let volumeCapsuleSpacing: CGFloat = Space.n6
    /// The gap between transport controls in the HUD.
    static let transportSpacingHUD: CGFloat = Space.n28
    /// The gap between transport controls in the docked bar.
    static let transportSpacingLegacy: CGFloat = Space.n16
    /// A utility glyph's point size.
    static let utilityGlyph = Icon.n16
    /// The volume glyph's point size.
    static let volumeGlyph = Icon.n14
    /// The title's font.
    static let titleFont = Typography.detailTitleStrong
    /// The subtitle's font.
    static let subtitleFont = Typography.caption
    /// The transport disc's glass corner is half its diameter.
    static func discCorner(for diameter: CGFloat) -> CGFloat { diameter / 2 }
  }

  // MARK: Settings

  /// Settings-specific geometry.
  enum Settings {
    /// The gap between sections.
    static let sectionSpacing: CGFloat = Space.n16
    /// The settings card's corner.
    static let cardCorner = Radius.settingsCard
    /// The section indicator's offset.
    static let indicatorOffset: CGFloat = Space.n8
    /// The vertical step between section indicator rows.
    static let sectionRowHeight: CGFloat = Size.n22
    /// The section indicator's animation.
    static let sectionIndicatorAnimation = Motion.n10
    /// The settings content's width.
    static let contentWidth = Size.settingsContentWidth
    /// The settings sidebar's width.
    static let sidebarWidth = Size.settingsSidebarWidth
    /// The settings window's width.
    static let windowWidth = Size.settingsWindowWidth
    /// The settings sidebar's maximum width.
    static let sidebarMaximum = Size.n220
    /// The settings content's minimum width.
    static let contentMinimum = Size.n430
    /// The settings preview's minimum height.
    static let previewMinimumHeight = Size.n120
    /// The settings preview's maximum height.
    static let previewMaximumHeight = Size.n400
  }

  // MARK: Aspect

  /// Aspect ratios used by media surfaces.
  enum Aspect {
    /// 16:9, the shape of a video frame.
    static let video: CGFloat = 16.0 / 9.0
  }

  // MARK: Windows

  /// Window geometry shared across controllers.
  enum Window {
    /// The library window's default size.
    static let defaultSize = Size.window
    /// The library window's minimum size.
    static let minimumSize = Size.minimumWindow
  }
}

// MARK: - AppKit conveniences

extension NSVisualEffectView {
  /// Applies a material token as one atomic configuration.
  func apply(_ token: Tokens.Material.VisualEffect) {
    material = token.material
    blendingMode = token.blending
    state = token.state
  }
}

extension NSColor {

  /// A colour that resolves differently in light and dark appearances.
  static func uniplayerDynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }

  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}
