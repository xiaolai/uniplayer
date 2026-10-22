//
//  PlayerHUDView.swift
//  uniplayer
//
//  The player's chrome as one overlay: controls at the top, transport in the
//  centre, metadata and a full-width timeline at the bottom. The empty area is
//  transparent to clicks, so the video keeps its own gestures.
//

import Cocoa

/// A clear Liquid Glass capsule that groups related HUD controls, the way the
/// system player groups its utility controls.
final class HUDCapsuleView: TranslucentView {
  init(content: NSView, horizontalPadding: CGFloat = Tokens.HUD.capsuleHorizontal,
       verticalPadding: CGFloat = Tokens.HUD.capsuleVertical) {
    super.init(liquidGlassCornerRadius: Tokens.HUD.capsuleCorner, vevCornerRadius: Tokens.HUD.capsuleCorner,
               padding: (horizontalPadding, verticalPadding))
    glassStyle = Tokens.Material.glassCapsule.style
    glassTintColor = Tokens.Material.glassCapsule.tint?.nsColor
    glassIsInteractive = Tokens.Material.glassCapsule.interactive
    setContent(content)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

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
  private let timelineGlass = NSGlassEffectView()
  private let dimLayer = CALayer()
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

    dimLayer.backgroundColor = Tokens.Palette.hudScrim.nsColor.cgColor
    layer?.addSublayer(dimLayer)

    topShade.colors = [
      Tokens.Palette.hudTopShade.nsColor.cgColor,
      Tokens.Palette.clear.nsColor.cgColor
    ]
    topShade.locations = [0, 1]
    bottomShade.colors = [
      Tokens.Palette.clear.nsColor.cgColor,
      Tokens.Palette.hudBottomShade.nsColor.cgColor
    ]
    bottomShade.locations = [0, 1]
    layer?.addSublayer(topShade)
    layer?.addSublayer(bottomShade)

    updateDim()

    titleLabel.font = Tokens.HUD.titleFont.nsFont
    titleLabel.textColor = Tokens.Palette.onMedia.nsColor
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = Tokens.HUD.subtitleFont.nsFont
    subtitleLabel.textColor = Tokens.Palette.onMediaSubtitle.nsColor
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let metadata = NSStackView(views: [subtitleLabel, titleLabel])
    metadata.translatesAutoresizingMaskIntoConstraints = false
    metadata.orientation = .vertical
    metadata.alignment = .leading
    metadata.spacing = Tokens.HUD.metadataSpacing

    [topLeading, topTrailing, center, bottomLeading, bottomTrailing].forEach { stack in
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = Tokens.HUD.controlSpacing
      addSubview(stack)
    }
    bottomLeading.addArrangedSubview(metadata)

    timelineGlass.translatesAutoresizingMaskIntoConstraints = false
    timelineGlass.style = Tokens.Material.glassTimeline.style
    timelineGlass.tintColor = Tokens.Material.glassTimeline.tint?.nsColor
    timelineGlass.cornerRadius = Tokens.HUD.timelineCorner
    addSubview(timelineGlass)

    timeline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(timeline)

    topLeadingConstraint = topLeading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.HUD.topLeadingWindow)

    NSLayoutConstraint.activate([
      topLeadingConstraint,
      topLeading.topAnchor.constraint(equalTo: topAnchor, constant: Tokens.HUD.topMargin),
      topTrailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.HUD.topMargin),
      topTrailing.centerYAnchor.constraint(equalTo: topLeading.centerYAnchor),

      center.centerXAnchor.constraint(equalTo: centerXAnchor),
      center.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Tokens.HUD.transportOffset),

      bottomLeading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.HUD.bottomMargin),
      bottomLeading.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -Tokens.HUD.metadataBottomGap),
      bottomLeading.trailingAnchor.constraint(lessThanOrEqualTo: bottomTrailing.leadingAnchor, constant: -Tokens.HUD.metadataTrailingGap),
      bottomTrailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.HUD.bottomMargin),
      bottomTrailing.centerYAnchor.constraint(equalTo: bottomLeading.centerYAnchor),

      timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.HUD.bottomMargin),
      timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.HUD.bottomMargin),
      timeline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Tokens.HUD.timelineBottom),
      timeline.heightAnchor.constraint(equalToConstant: Tokens.HUD.timelineHeight),
      timelineGlass.leadingAnchor.constraint(equalTo: timeline.leadingAnchor),
      timelineGlass.trailingAnchor.constraint(equalTo: timeline.trailingAnchor),
      timelineGlass.topAnchor.constraint(equalTo: timeline.topAnchor),
      timelineGlass.bottomAnchor.constraint(equalTo: timeline.bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    dimLayer.frame = bounds
    let topHeight: CGFloat = min(Tokens.HUD.topShadeHeight, bounds.height * Tokens.HUD.topShadeFraction)
    let bottomHeight: CGFloat = min(Tokens.HUD.bottomShadeHeight, bounds.height * Tokens.HUD.bottomShadeFraction)
    topShade.frame = CGRect(
      x: 0, y: bounds.height - topHeight,
      width: bounds.width, height: topHeight)
    bottomShade.frame = CGRect(
      x: 0, y: 0, width: bounds.width, height: bottomHeight)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateDim()
  }

  private func updateDim() {
    let increase = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    dimLayer.backgroundColor = (increase ? Tokens.Palette.hudScrimIncreased : Tokens.Palette.hudScrim).nsColor.cgColor
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
    topLeadingConstraint.constant = fullScreen ? Tokens.HUD.topLeadingFullScreen : Tokens.HUD.topLeadingWindow
  }
}
