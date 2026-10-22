//
//  AdditionalInfoView.swift
//  uniplayer
//
//  Created by Hechen Li on 2026-05-27.
//  Copyright © 2026 lhc. All rights reserved.
//

class AdditionalInfoView: TranslucentView {
  var stackView: NSStackView!
  var timeLabel: NSTextField!
  var title: NSTextField!
  var batteryView: NSView!
  var batteryLabel: NSTextField!

  weak var mainWindow: MainWindowController!

  private var accessoryView: NSView?

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow

    let container = NSView()

    self.title = NSTextField(labelWithString: "")
    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = Tokens.Typography.detailTitle.nsFont
    // priority must be in (250, 500) so it grows but can be compressed by window width
    title.setContentCompressionResistancePriority(
      NSLayoutConstraint.Priority(rawValue: 300),
      for: .horizontal
    )

    self.stackView = NSStackView()
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.orientation = .horizontal
    stackView.alignment = .centerY
    stackView.spacing = 4

    self.timeLabel = NSTextField(labelWithString: "")
    timeLabel.font = Tokens.Typography.monoTitle.nsFont
    timeLabel.textColor = Tokens.Palette.textSecondary.nsColor
    timeLabel.translatesAutoresizingMaskIntoConstraints = false

    let separator = NSBox()
    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.boxType = .separator
    separator.size(width: Tokens.Size.n2, height: Tokens.Size.n16)

    let batteryImage = NSImageView(image: .battery)
    batteryImage.translatesAutoresizingMaskIntoConstraints = false

    self.batteryLabel = NSTextField(labelWithString: "")
    batteryLabel.translatesAutoresizingMaskIntoConstraints = false
    batteryLabel.font = Tokens.Typography.bodyStrong.nsFont
    batteryLabel.textColor = Tokens.Palette.textSecondary.nsColor

    self.batteryView = NSView()
    batteryView.translatesAutoresizingMaskIntoConstraints = false
    batteryView.addSubview(batteryImage)
    batteryView.addSubview(batteryLabel)
    batteryImage.padding(.all(Tokens.Space.n0))
    batteryLabel.center()

    super.init(liquidGlassCornerRadius: 16, vevCornerRadius: 10, padding: (16, 8))

    if let clockImage = NSImage.sf(["clock"])?
      .withSymbolConfiguration(.init(pointSize: 18, weight: .bold)) {
      let timeImage = NSImageView(image: clockImage)
      timeImage.translatesAutoresizingMaskIntoConstraints = false
      timeImage.size(width: Tokens.Size.n24, height: Tokens.Size.n24)
      stackView.addArrangedSubview(timeImage)
    }
    stackView.addArrangedSubview(timeLabel)
    stackView.addArrangedSubview(separator)
    stackView.addArrangedSubview(batteryView)

    container.addSubview(title)
    container.addSubview(stackView)
    title.padding(.top, .horizontal).spacing(.bottom(Tokens.Space.n8), to: stackView)
    stackView.padding(.bottom, .trailing, .leading(greaterThan: 0))
    setContent(container)
  }
  
  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update() {
    timeLabel.stringValue = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
    title.stringValue = window?.representedURL?.lastPathComponent ?? window?.title ?? ""
    if let capacity = PowerSource.getList().filter({ $0.type == "InternalBattery" }).first?.currentCapacity {
      batteryLabel.stringValue = "\(capacity)%"
      stackView.setVisibilityPriority(.mustHold, for: batteryView)
    } else {
      stackView.setVisibilityPriority(.notVisible, for: batteryView)
    }
  }
}
