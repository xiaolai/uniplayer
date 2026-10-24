//
//  CaptionOverlayController.swift
//  uniplayer
//
//  The single owner of an mpv OSD overlay. Subtitle-file translation and live
//  translation each hold one instance with a distinct overlay ID so they can
//  never draw over each other.
//

import Cocoa

final class CaptionOverlayController {
  private struct Rendered: Equatable {
    let text: String
    let style: SubtitleOverlayStyle
    let playWidth: Double
    let playHeight: Double
  }

  private static let minimumInterval: TimeInterval = 0.1

  private unowned let player: PlayerCore
  private let overlayID: String
  private var rendered: Rendered?
  private var visible = false
  private var lastDrawAt = Date.distantPast
  private var pendingText: String?
  private var pendingWork: DispatchWorkItem?

  init(player: PlayerCore, overlayID: String) {
    self.player = player
    self.overlayID = overlayID
  }

  deinit {
    pendingWork?.cancel()
  }

  var isVisible: Bool { visible }

  /// Throttles updates to about 10 Hz; `immediate` is for final results and
  /// state changes where a 100 ms delay would be visible.
  func show(text: String, immediate: Bool = false) {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastDrawAt)
    if immediate || elapsed >= Self.minimumInterval {
      pendingWork?.cancel()
      pendingWork = nil
      pendingText = nil
      draw(text)
      lastDrawAt = now
    } else {
      pendingText = text
      pendingWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self, let text = self.pendingText else { return }
        self.pendingText = nil
        self.pendingWork = nil
        self.draw(text)
        self.lastDrawAt = Date()
      }
      pendingWork = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + (Self.minimumInterval - elapsed), execute: work)
    }
  }

  func clear() {
    pendingWork?.cancel()
    pendingWork = nil
    pendingText = nil
    guard visible else {
      rendered = nil
      return
    }
    visible = false
    rendered = nil
    guard player.mpv != nil, player.info.state.active else { return }
    player.mpv.command(.osdOverlay, args: [
      overlayID, "none", "", "0", "0", "0", "no",
    ], checkError: false, level: .verbose) { [weak self] code in
      if code < 0 {
        self?.player.log("Failed to clear the caption overlay (\(code))",
                         level: .warning)
      }
    }
  }

  private func draw(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          player.info.state.active, player.mpv != nil,
          player.info.isSubVisible,
          let dimensions = dimensions() else {
      clear()
      return
    }
    let style = overlayStyle()
    let next = Rendered(
      text: trimmed, style: style,
      playWidth: dimensions.width, playHeight: dimensions.height)
    guard next != rendered else { return }

    let event = style.assEvent(
      text: trimmed, playWidth: dimensions.width, playHeight: dimensions.height)
    player.mpv.command(.osdOverlay, args: [
      overlayID, "ass-events", event,
      "\(Int(dimensions.width.rounded()))", "\(Int(dimensions.height.rounded()))",
      "10", "no",
    ], checkError: false, level: .verbose) { [weak self] code in
      if code < 0 {
        self?.player.log("Failed to draw the caption overlay (\(code))",
                         level: .warning)
      }
    }
    rendered = next
    visible = true
  }

  private func dimensions() -> (width: Double, height: Double)? {
    var width = player.mpv.getInt(MPVProperty.dwidth)
    var height = player.mpv.getInt(MPVProperty.dheight)
    if width <= 0 || height <= 0 {
      width = player.mpv.getInt(MPVProperty.width)
      height = player.mpv.getInt(MPVProperty.height)
      let rotation = ((player.mpv.getInt(MPVProperty.videoParamsRotate) % 360) + 360) % 360
      if rotation == 90 || rotation == 270 {
        swap(&width, &height)
      }
    }
    guard width > 0, height > 0 else { return nil }
    let playHeight = 720.0
    let playWidth = (playHeight * Double(width) / Double(height)).clamped(to: 100...5000)
    return (playWidth, playHeight)
  }

  private func overlayStyle() -> SubtitleOverlayStyle {
    var style = SubtitleOverlayStyle()

    if let font = player.mpv.getString(MPVOption.Subtitles.subFont), !font.isEmpty {
      style.fontName = font
    }
    let size = player.mpv.getDouble(MPVOption.Subtitles.subFontSize)
    let scale = abs(player.mpv.getDouble(MPVOption.Subtitles.subScale))
    style.fontSize = (size > 0 ? size : 55) * (scale > 0.01 ? scale : 1) // token-exempt: mpv --sub-font-size default
    style.bold = player.mpv.getFlag(MPVOption.Subtitles.subBold)
    style.italic = player.mpv.getFlag(MPVOption.Subtitles.subItalic)
    style.textColor = mpvColor(MPVOption.Subtitles.subColor, fallback: .white) // token-exempt: mpv subtitle colour default
    style.outlineColor = mpvColor(MPVOption.Subtitles.subOutlineColor, fallback: .black) // token-exempt: mpv subtitle colour default
    style.backColor = mpvColor(MPVOption.Subtitles.subBackColor, fallback: .black) // token-exempt: mpv subtitle colour default
    style.shadowColor = style.backColor

    let outline = player.mpv.getDouble(MPVOption.Subtitles.subOutlineSize)
    if outline >= 0 { style.outlineSize = outline }
    let shadow = player.mpv.getDouble(MPVOption.Subtitles.subShadowOffset)
    if shadow >= 0 { style.shadowOffset = shadow }
    if let borderStyle = player.mpv.getString(MPVOption.Subtitles.subBorderStyle),
       !borderStyle.isEmpty {
      style.borderStyle = borderStyle
    }
    style.verticalPosition = player.mpv.getDouble(MPVOption.Subtitles.secondarySubPos)
    if let alignment = player.mpv.getString(MPVOption.Subtitles.subAlignX), !alignment.isEmpty {
      style.horizontalAlignment = alignment
    }
    let marginX = player.mpv.getDouble(MPVOption.Subtitles.subMarginX)
    if marginX >= 0 { style.marginX = marginX }
    let marginY = player.mpv.getDouble(MPVOption.Subtitles.subMarginY)
    if marginY >= 0 { style.marginY = marginY }
    return style
  }

  private func mpvColor(_ option: String,
                        fallback: SubtitleOverlayColor) -> SubtitleOverlayColor {
    guard let raw = player.mpv.getString(option),
          let color = NSColor(mpvColorString: raw)?.usingColorSpace(.sRGB) else { // token-exempt: parses an mpv colour value, not a design value
      return fallback
    }
    return SubtitleOverlayColor(
      red: Double(color.redComponent),
      green: Double(color.greenComponent),
      blue: Double(color.blueComponent),
      alpha: Double(color.alphaComponent))
  }
}
