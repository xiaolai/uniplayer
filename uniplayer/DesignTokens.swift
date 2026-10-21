//
//  DesignTokens.swift
//  uniplayer
//
//  The single source of truth for the library's colour, type and geometry.
//  Both AppKit and SwiftUI read these values; a hard-coded colour or font in a
//  view is a bug, not a shortcut.
//

import AppKit
import SwiftUI

enum Tokens {

  // MARK: - Colour

  /// The page behind the shelves.
  static let canvas = Color(nsColor: .uniplayerDynamic(
    light: NSColor(hex: 0xF2F2F5),
    dark: NSColor(hex: 0x0E0E12)))

  /// The sidebar and other chrome that sits beside the content.
  static let sidebar = Color(nsColor: .uniplayerDynamic(
    light: NSColor(hex: 0xE9E9EE),
    dark: NSColor(hex: 0x15151A)))

  /// A raised surface: cards, sheets and the search field's backing.
  static let surface = Color(nsColor: .uniplayerDynamic(
    light: NSColor(hex: 0xFFFFFF),
    dark: NSColor(hex: 0x1C1C22)))

  static let textPrimary = Color(nsColor: .labelColor)
  static let textSecondary = Color(nsColor: .secondaryLabelColor)
  static let textTertiary = Color(nsColor: .tertiaryLabelColor)
  static let hairline = Color(nsColor: .separatorColor)
  static let accent = Color(nsColor: .controlAccentColor)

  /// The shade that makes white text legible over a frame of any brightness.
  static let cardShade = Color.black.opacity(0.78)
  static let heroShade = Color.black.opacity(0.88)

  // MARK: - Type

  static let heroTitle = Font.system(size: 34, weight: .bold)
  static let heroBody = Font.system(size: 15, weight: .regular)
  static let sectionTitle = Font.system(size: 17, weight: .semibold)
  static let cardTitle = Font.system(size: 13, weight: .semibold)
  static let body = Font.system(size: 13, weight: .regular)
  static let caption = Font.system(size: 11, weight: .regular)
  static let button = Font.system(size: 13, weight: .medium)

  // MARK: - Geometry

  static let defaultWindowSize = NSSize(width: 1220, height: 720)
  static let minimumWindowSize = NSSize(width: 900, height: 560)
  static let sidebarWidth: CGFloat = 220
  static let contentPadding: CGFloat = 40
  static let sectionSpacing: CGFloat = 32
  static let cardWidth: CGFloat = 215
  static let cardHeight: CGFloat = 151
  static let gridMinimum: CGFloat = 200
  static let gridMaximum: CGFloat = 280
  static let gridSpacing: CGFloat = 20

  static let cardCorner: CGFloat = 10
  static let heroCorner: CGFloat = 14

  // MARK: - Motion

  static let hover = Animation.easeOut(duration: 0.16)
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
