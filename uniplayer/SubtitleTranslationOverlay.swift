//
//  SubtitleTranslationOverlay.swift
//  uniplayer
//
//  Builds the ASS event used by mpv's `osd-overlay` command. The overlay is
//  independent of the subtitle track list and of the user's secondary track,
//  and it follows the current subtitle styling and secondary position.
//

import Foundation

struct SubtitleOverlayColor: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = red.clamped(to: 0...1)
    self.green = green.clamped(to: 0...1)
    self.blue = blue.clamped(to: 0...1)
    self.alpha = alpha.clamped(to: 0...1)
  }

  // These mirror mpv's subtitle-colour defaults, not the app's design palette.
  static let white = SubtitleOverlayColor(red: 1, green: 1, blue: 1, alpha: 1) // token-exempt: mpv subtitle colour component
  static let black = SubtitleOverlayColor(red: 0, green: 0, blue: 0, alpha: 1) // token-exempt: mpv subtitle colour component
  static let clear = SubtitleOverlayColor(red: 0, green: 0, blue: 0, alpha: 0) // token-exempt: mpv subtitle colour component
}

/// Everything that affects how the translated line is drawn.
struct SubtitleOverlayStyle: Equatable {
  // Defaults mirror mpv's subtitle options; every value is replaced from the
  // running mpv instance before the overlay is drawn.
  var fontName: String = "sans-serif"
  var fontSize: Double = 55 // token-exempt: mpv --sub-font-size default
  var bold: Bool = false
  var italic: Bool = false
  var textColor: SubtitleOverlayColor = .white // token-exempt: mpv --sub-color default
  var outlineColor: SubtitleOverlayColor = .black // token-exempt: mpv --sub-outline-color default
  var shadowColor: SubtitleOverlayColor = .clear // token-exempt: mpv --sub-back-color default
  var backColor: SubtitleOverlayColor = .black // token-exempt: mpv --sub-back-color default
  var outlineSize: Double = 1.65 // token-exempt: mpv --sub-outline-size default
  var shadowOffset: Double = 0
  var borderStyle: String = "outline-and-shadow"
  var verticalPosition: Double = 0
  var horizontalAlignment: String = "center"
  var marginX: Double = 19 // token-exempt: mpv --sub-margin-x default
  var marginY: Double = 34 // token-exempt: mpv --sub-margin-y default

  /// A single ASS event line for `osd-overlay`'s `ass-events` format.
  ///
  /// The event is anchored at the secondary subtitle position: 0 is the top
  /// of the video and 100 the bottom, matching mpv's `secondary-sub-pos`.
  func assEvent(text: String, playWidth: Double, playHeight: Double) -> String {
    let layout = Self.layout(
      playWidth: playWidth,
      playHeight: playHeight,
      verticalPosition: verticalPosition,
      horizontalAlignment: horizontalAlignment,
      marginX: marginX,
      marginY: marginY)

    var tags = "\\an\(layout.alignment)\\pos(\(Self.number(layout.x)),\(Self.number(layout.y)))"
    tags += "\\fn\(Self.escapedFontName(fontName))"
    tags += "\\fs\(Self.number(fontSize.clamped(to: 1...2000)))"
    tags += "\\c\(Self.assColor(textColor))"
    if bold { tags += "\\b1" }
    if italic { tags += "\\i1" }

    switch borderStyle.lowercased() {
    case "opaque-box", "background-box":
      // ASS cannot switch BorderStyle per event. A thick border in the
      // background colour is the closest approximation of the box styles.
      tags += "\\bord\(Self.number(max(outlineSize, 2.0)))"
      tags += "\\3c\(Self.assColor(backColor))"
      tags += "\\shad0"
    default:
      tags += "\\bord\(Self.number(outlineSize.clamped(to: 0...100)))"
      tags += "\\3c\(Self.assColor(outlineColor))"
      tags += "\\shad\(Self.number(shadowOffset.clamped(to: 0...100)))"
      tags += "\\4c\(Self.assColor(shadowColor))"
    }

    return "{\(tags)}\(Self.escapedText(text))"
  }

  // MARK: - Layout

  static func layout(playWidth: Double,
                     playHeight: Double,
                     verticalPosition: Double,
                     horizontalAlignment: String,
                     marginX: Double,
                     marginY: Double) -> (alignment: Int, x: Double, y: Double) {
    let vertical = verticalPosition.clamped(to: 0...150)
    let topAnchored = vertical <= 50
    var y = playHeight * vertical / 100
    y = topAnchored ? min(playHeight, y + marginY) : max(0, y - marginY)

    let x: Double
    let alignment: Int
    switch horizontalAlignment.lowercased() {
    case "left":
      x = marginX
      alignment = topAnchored ? 7 : 1
    case "right":
      x = playWidth - marginX
      alignment = topAnchored ? 9 : 3
    default:
      x = playWidth / 2
      alignment = topAnchored ? 8 : 2
    }
    return (alignment, x, y)
  }

  // MARK: - Escaping

  /// Escapes text for an ASS event.
  ///
  /// ASS treats `{…}` as override tags and backslash sequences such as `\N`
  /// specially, so both are escaped. Real line breaks become `\N`, the ASS
  /// line-break tag.
  static func escapedText(_ text: String) -> String {
    var cleaned = ""
    cleaned.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\n", "\t", " ":
        cleaned.unicodeScalars.append(scalar)
      default:
        if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { continue }
        cleaned.unicodeScalars.append(scalar)
      }
    }
    // Provider output is an external boundary; keep a pathological answer
    // from producing a multi-megabyte overlay command.
    if cleaned.count > 4000 {
      cleaned = String(cleaned.prefix(4000))
    }
    cleaned = cleaned.replacingOccurrences(of: "\\", with: "\\\\")
    cleaned = cleaned.replacingOccurrences(of: "{", with: "\\{")
    cleaned = cleaned.replacingOccurrences(of: "}", with: "\\}")
    cleaned = cleaned.replacingOccurrences(of: "\t", with: " ")
    return cleaned.replacingOccurrences(of: "\n", with: "\\N")
  }

  private static func escapedFontName(_ name: String) -> String {
    let cleaned = name
      .replacingOccurrences(of: "\\", with: "")
      .replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
      .replacingOccurrences(of: ",", with: "")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "sans-serif" : cleaned
  }

  /// ASS colours are `&HAABBGGRR&`; alpha is inverted (00 is opaque).
  static func assColor(_ color: SubtitleOverlayColor) -> String {
    let alpha = 255 - Int((color.alpha * 255).rounded())
    let red = Int((color.red * 255).rounded())
    let green = Int((color.green * 255).rounded())
    let blue = Int((color.blue * 255).rounded())
    return String(format: "&H%02X%02X%02X%02X&",
                  alpha.clamped(to: 0...255),
                  blue.clamped(to: 0...255),
                  green.clamped(to: 0...255),
                  red.clamped(to: 0...255))
  }

  private static func number(_ value: Double) -> String {
    // ASS parses a dot as the decimal separator; a comma from a localized
    // formatter would split the tag at the wrong place.
    String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}
