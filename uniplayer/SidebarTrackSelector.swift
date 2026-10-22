//
//  SidebarTrackSelector.swift
//  uniplayer
//
//  Created by Hechen Li on 2026-06-14.
//  Copyright © 2026 lhc. All rights reserved.
//

class TrackSelector: NSScrollView, NSTableViewDelegate, NSTableViewDataSource {
  private let trackType: MPVTrack.TrackType
  private unowned let player: PlayerCore

  private var tableView: NSTableView

  init(_ trackType: MPVTrack.TrackType, player: PlayerCore, observedKeys: [Notification.Name]) {
    self.player = player
    self.trackType = trackType
    self.tableView = NSTableView()
    super.init(frame: .zero)

    tableView.delegate = self
    tableView.dataSource = self
    tableView.style = .plain

    tableView.addTableColumn(NSTableColumn(identifier: .trackName))
    tableView.headerView = nil
    tableView.backgroundColor = Tokens.Palette.clear.nsColor
    tableView.gridStyleMask = [.solidHorizontalGridLineMask]

    translatesAutoresizingMaskIntoConstraints = false
    documentView = tableView
    drawsBackground = false
    wantsLayer = true
    layer?.cornerRadius = Tokens.Radius.n8
    size(height: 98)

    player.observe(.iinaTracklistChanged) { [weak self] _ in
      self?.tableView.reloadData()
    }
    for key in observedKeys {
      player.observe(key) { [weak self] _ in
        self?.tableView.reloadData()
      }
    }
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  func numberOfRows(in tableView: NSTableView) -> Int {
    return player.info.trackList(trackType).count + 1
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    return 26
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let trackList = player.info.trackList(trackType)
    guard let column = tableColumn, row <= trackList.count else { return nil }

    let track = row == 0 ? nil : trackList[at: row - 1]
    let selectedTrack = player.info.currentTrack(trackType)

    let columnID = column.identifier
    let identifier = NSUserInterfaceItemIdentifier("\(columnID.rawValue)Cell")

    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CellView ?? {
      let cell = CellView()
      cell.identifier = identifier
      return cell
    }()
    let isChosen = track == selectedTrack
    switch columnID {
    case .trackName:
      cell.textField?.textColor = row == 0 ? Tokens.Palette.textSecondary.nsColor : Tokens.Palette.textPrimary.nsColor
      cell.textField?.stringValue = track?.readableString(includingLanguage: false) ?? Constants.String.trackNone
      cell.selectedIndicator.isHidden = !isChosen
      cell.setLanguage(track?.readableLanguage)
    default:
      break
    }
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard tableView.numberOfSelectedRows > 0 else { return }
    let trackId = if tableView.selectedRow > 0 {
      player.info.trackList(trackType)[tableView.selectedRow-1].id
    } else {
      0
    }
    player.setTrack(trackId, forType: trackType)
    tableView.deselectAll(nil)
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier, columnID: NSUserInterfaceItemIdentifier) -> CellView {
    let cell = CellView()
    cell.identifier = identifier
    return cell
  }

  private class CellView: NSTableCellView {
    var selectedIndicator: ColoredView
    var languageTag: ColoredView
    var languageLabel: NSTextField

    override init(frame frameRect: NSRect) {
      self.selectedIndicator = ColoredView(color: .controlAccentColor, cornerRadius: Tokens.Radius.n2)
      selectedIndicator.translatesAutoresizingMaskIntoConstraints = false

      self.languageTag = ColoredView(color: .controlColor, cornerRadius: Tokens.Radius.n3)
      languageTag.translatesAutoresizingMaskIntoConstraints = false

      self.languageLabel = NSTextField(labelWithString: "")
      languageLabel.translatesAutoresizingMaskIntoConstraints = false

      super.init(frame: frameRect)

      let textField = NSTextField(labelWithString: "")
      textField.isSelectable = false
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.lineBreakMode = .byTruncatingMiddle
      textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      addSubview(textField)
      textField.padding(.leading(Tokens.Space.n12)).center(.y)
      self.textField = textField

      addSubview(selectedIndicator)
      selectedIndicator.padding(.leading, .vertical(Tokens.Space.n5))
        .size(width: Tokens.Size.n4)

      languageLabel.font = Tokens.Typography.caption.nsFont

      languageTag.addSubview(languageLabel)
      languageLabel.padding(.vertical(Tokens.Space.n1), .horizontal(Tokens.Space.n2))

      addSubview(languageTag)
      languageTag.padding(.trailing)
        .spacing(.leading(greaterThan: 4), to: textField)
        .center(.y)
    }

    func setLanguage(_ language: String?) {
      if let language, !language.isEmpty {
        languageTag.isHidden = false
        languageLabel.stringValue = language
      } else {
        languageTag.isHidden = true
      }
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }
}

class ColoredView: NSView {
  let color: NSColor
  let cornerRadius: CGFloat

  init(color: NSColor, cornerRadius: CGFloat = 0) {
    self.color = color
    self.cornerRadius = cornerRadius
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
  }
}
