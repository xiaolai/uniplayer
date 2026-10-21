//
//  PlayerHUDView.swift
//  uniplayer
//
//  The player's chrome as one overlay: controls at the top, transport in the
//  centre, metadata and a full-width timeline at the bottom. The empty area is
//  transparent to clicks, so the video keeps its own gestures.
//

import Cocoa

final class PlayerHUDView: NSView {

  weak var mainWindow: MainWindowController!

  let topLeading = NSStackView()
  let topTrailing = NSStackView()
  let center = NSStackView()
  let bottomLeading = NSStackView()
  let bottomTrailing = NSStackView()
  let timeline = NSView()

  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let topShade = CAGradientLayer()
  private let bottomShade = CAGradientLayer()

  private var topLeadingConstraint: NSLayoutConstraint!
  private var isFullScreen = false

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true

    topShade.colors = [
      NSColor.black.withAlphaComponent(0.62).cgColor,
      NSColor.clear.cgColor
    ]
    topShade.locations = [0, 1]
    bottomShade.colors = [
      NSColor.clear.cgColor,
      NSColor.black.withAlphaComponent(0.84).cgColor
    ]
    bottomShade.locations = [0, 1]
    layer?.addSublayer(topShade)
    layer?.addSublayer(bottomShade)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = .systemFont(ofSize: 11)
    subtitleLabel.textColor = .white.withAlphaComponent(0.72)
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let metadata = NSStackView(views: [titleLabel, subtitleLabel])
    metadata.translatesAutoresizingMaskIntoConstraints = false
    metadata.orientation = .vertical
    metadata.alignment = .leading
    metadata.spacing = 3

    [topLeading, topTrailing, center, bottomLeading, bottomTrailing].forEach { stack in
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = 8
      addSubview(stack)
    }
    bottomLeading.addArrangedSubview(metadata)

    timeline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(timeline)

    topLeadingConstraint = topLeading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84)

    NSLayoutConstraint.activate([
      topLeadingConstraint,
      topLeading.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      topTrailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
      topTrailing.centerYAnchor.constraint(equalTo: topLeading.centerYAnchor),

      center.centerXAnchor.constraint(equalTo: centerXAnchor),
      center.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),

      bottomLeading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
      bottomLeading.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -14),
      bottomLeading.trailingAnchor.constraint(lessThanOrEqualTo: bottomTrailing.leadingAnchor, constant: -16),
      bottomTrailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
      bottomTrailing.centerYAnchor.constraint(equalTo: bottomLeading.centerYAnchor),

      timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
      timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
      timeline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
      timeline.heightAnchor.constraint(equalToConstant: 24)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    let topHeight: CGFloat = min(140, bounds.height * 0.3)
    let bottomHeight: CGFloat = min(220, bounds.height * 0.45)
    topShade.frame = CGRect(
      x: 0, y: bounds.height - topHeight,
      width: bounds.width, height: topHeight)
    bottomShade.frame = CGRect(
      x: 0, y: 0, width: bounds.width, height: bottomHeight)
  }

  /// Empty HUD space belongs to the video, not to the chrome.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func updateMetadata(title: String, subtitle: String) {
    titleLabel.stringValue = title
    subtitleLabel.stringValue = subtitle
    subtitleLabel.isHidden = subtitle.isEmpty
  }

  func updateForFullScreen(_ fullScreen: Bool) {
    guard isFullScreen != fullScreen else { return }
    isFullScreen = fullScreen
    topLeadingConstraint.constant = fullScreen ? 24 : 84
  }
}
