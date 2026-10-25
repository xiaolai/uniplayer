//
//  SettingsPageUI.swift
//  uniplayer
//
//  Created by Hechen Li on 6/13/25.
//  Copyright © 2025 lhc. All rights reserved.
//

fileprivate let ui = SettingsUIHelper.sharedUI

class SettingsPageUI: SettingsPage {
  private lazy var windowInitialSizeView: WindowInitialSizeView = WindowInitialSizeView(geometryBindings: geometryBindings)
  private lazy var windowInitialPositionView: WindowInitialPositionView = WindowInitialPositionView(geometryBindings: geometryBindings)
  private lazy var resizeWindowView: ResizeWindowView = ResizeWindowView()
  private lazy var oscLayoutView: OSCLayoutView = OSCLayoutView()
  private lazy var oscToolbarView: OSCToolbarView = OSCToolbarView()

  private lazy var geometryBindings = GeometryBindings()

  override var identifier: String {
    "ui"
  }

  override var title: String {
    return NSLocalizedString("preference.ui", comment: "UI")
  }

  override var image: NSImage {
    return .sf("macwindow", withConfiguration: symbolConfiguration)!
  }

  override var localizationTable: String {
    "SettingsUILocalizable"
  }

  override var helpInfo: String? {
    ui.localized("more_ui_settings")
  }

  override func pageLoaded() {
    geometryBindings.updateControls()
  }

  override func content() -> [SettingsSection] {
    return sections {
      sectionAppearance()
      sectionWindow()
      sectionOSC().onlyInAdvanced()
      sectionOSD()
      sectionThumbnail().onlyInAdvanced()
      sectionPIP()
      sectionAccessibility()
    }
  }

  private func sectionAppearance() -> SettingsSection {
    return section {
      SettingsList(title: .text_Appearance) {
        SettingsItem.Custom().view(textSizeControl())

        SettingsItem.General(title: .general("sidebar.liquid_glass"))
          .image(name: ["capsule.on.rectangle.liquid.glass", "liquid.glass"])
          .withExpandingDetailView {
            SettingsItem.Switch(title: .text_OnScreenDisplay)
              .bindTo(.useLiquidGlassOSD)
            SettingsItem.Switch(title: .text_OnScreenController)
              .bindTo(.useLiquidGlassOSC)
            SettingsItem.Switch(title: .general("sidebar.sidebar"))
              .bindTo(.useLiquidGlassSidebar)
          }
        SettingsItem.Switch(title: .general("sidebar.compact_interface"))
          .image(name: "rectangle.grid.3x2.fill")
          .bindTo(.compactUI)
      }
    }
  }

  private func textSizeControl() -> NSView {
    let label = NSTextField(labelWithString: NSLocalizedString("Library and Assistant Text Size", comment: "Interface"))
    label.font = Tokens.Typography.settingsRowTitle.nsFont
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["100%", "125%", "150%", "200%"])
    let scale = UserDefaults.standard.double(forKey: "interface.textScale.v1")
    popup.selectItem(at: [1.0, 1.25, 1.5, 2.0].firstIndex(of: scale) ?? 0)
    popup.target = self
    popup.action = #selector(changeTextSize(_:))
    popup.setAccessibilityLabel(label.stringValue)
    let stack = NSStackView(views: [label, popup])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Tokens.Space.n8
    stack.edgeInsets = NSEdgeInsets(top: Tokens.Space.n10, left: Tokens.Space.n12,
                                  bottom: Tokens.Space.n10, right: Tokens.Space.n12)
    return stack
  }

  @objc private func changeTextSize(_ sender: NSPopUpButton) {
    let values = [1.0, 1.25, 1.5, 2.0]
    guard values.indices.contains(sender.indexOfSelectedItem) else { return }
    UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "interface.textScale.v1")
  }

  private func sectionWindow() -> SettingsSection {
    return section {
      SettingsList(title: .text_Window) {
        SettingsItem.Switch(title: .text_InitialWindowSize)
          .image(name: "custom.arrow.up.left.and.down.right.and.arrow.up.right.and.down.left.rectangle")
          .withExpandingDetailView(windowInitialSizeView)
          .bindToCustom {
            self.geometryBindings.initControl(\.windowSizeSwitch, $0)
          }
          .bindExpandableView()
        SettingsItem.Switch(title: .text_InitialWindowPosition)
          .image(name: "arrow.up.and.down.and.arrow.left.and.right")
          .withExpandingDetailView(windowInitialPositionView)
          .bindToCustom {
            self.geometryBindings.initControl(\.windowPosSwitch, $0)
          }
          .bindExpandableView()
      }

      SettingsList {
        SettingsItem.PopupButton()
          .image(name: "arrow.up.left.bottomright.rectangle")
          .bindTo(.resizeWindowOption, ofType: Preference.ResizeWindowOption.self)
          .withDetailView(resizeWindowView)
      }

      SettingsList {
        SettingsItem.Switch()
          .image(name: "desktopcomputer")
          .bindTo(.usePhysicalResolution)
      }

      SettingsList {
        SettingsItem.Switch()
          .image(name: "square.2.layers.3d.top.filled")
          .bindTo(.alwaysFloatOnTop)
        SettingsItem.Switch()
          .image(name: "pin.square")
          .bindTo(.alwaysShowOnTopIcon)
      }
    }
  }

  private func playerControlsNote() -> NSView {
    let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
      "These options customize the separate player window. Library playback uses compact inline controls.", comment: "Interface"))
    note.font = Tokens.Typography.caption.nsFont
    note.textColor = Tokens.Palette.textSecondary.nsColor
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    note.translatesAutoresizingMaskIntoConstraints = false
    wrapper.addSubview(note)
    note.padding(.horizontal(Tokens.Space.n12), .vertical(Tokens.Space.n10))
    return wrapper
  }

  private func sectionOSC() -> SettingsSection {
    return section {
      SettingsList(title: .text_OnScreenController) {
        SettingsItem.Custom().view(playerControlsNote())
        SettingsItem.General(title: .text_Layout)
          .image(name: "menubar.dock.rectangle")
          .withDetailView(oscLayoutView)
        SettingsItem.General(title: .text_Toolbar)
          .image(name: "ellipsis.rectangle")
          .withDetailView(oscToolbarView)
      }

      SettingsList() {
        SettingsItem.PopupButton()
          .image(name: "forward.fill")
          .bindTo(.arrowButtonAction, ofType: Preference.ArrowButtonAction.self)
        SettingsItem.SwitchWithInput()
          .image(name: "timer")
          .labelKey(.controlBarAutoHideTimeout)
          .bindInputTo(.controlBarAutoHideTimeout)
          .bindSwitchTo(.enableControlBarAutoHide)
          .range(0...Double(Int.max), allowsFloats: true)
          .trailingLabel(.text_s)
      }

      SettingsList {
        SettingsItem.Switch()
          .image(name: "arrow.right.and.line.vertical.and.arrow.left")
          .bindTo(.controlBarStickToCenter)
        SettingsItem.Switch()
          .image(name: "ruler")
          .bindTo(.showChapterPos)
        SettingsItem.Switch()
          .image(name: "slider.horizontal.below.square.and.square.filled")
          .bindTo(.showRemainingTime)
          .withDetailView {
            SettingsItem.Switch()
              .bindTo(.scaleRemainingTime)
          }
        SettingsItem.Switch()
          .image(name: "custom.computermouse.slash")
          .bindTo(.disablePlaySliderScrolling)
        SettingsItem.Switch()
          .bindTo(.disableVolumeSliderScrolling)
      }
    }
  }

  private func sectionOSD() -> SettingsSection {
    return section {
      SettingsList(title: .text_OnScreenDisplay) {
        SettingsItem.Switch()
          .image(name: ["inset.filled.topleft.rectangle", "app.badge"])
          .bindTo(.enableOSD)
        SettingsItem.General(title: .text_SuppressMessagesFor)
          .withExpandingDetailView {
            SettingsItem.Switch()
              .bindTo(.disableOSDFileStartMsg)
            SettingsItem.Switch()
              .bindTo(.disableOSDPauseResumeMsgs)
            SettingsItem.Switch()
              .bindTo(.disableOSDSeekMsg)
            SettingsItem.Switch()
              .bindTo(.disableOSDSpeedMsg)
          }
      }

      SettingsList() {
        SettingsItem.Input(title: .controlBarAutoHideTimeoutLabel)
          .image(name: "timer")
          .bindTo(.osdAutoHideTimeout)
          .range(0...Double(Int.max), allowsFloats: true)
          .trailingLabel(.text_s)
        SettingsItem.Input()
          .image(name: "textformat.size")
          .bindTo(.osdTextSize)
          .range(1...500)
          .trailingLabel(.text_pt)
        SettingsItem.Switch()
          .image(name: "info.bubble")
          .bindTo(.displayTimeAndBatteryInFullScreen)
      }
    }
  }

  private func sectionThumbnail() -> SettingsSection {
    return section {
      SettingsList(title: .text_ThumbnailPreview) {
        SettingsItem.Switch()
          .image(name: "custom.photo.bubble.left")
          .bindTo(.enableThumbnailPreview)
          .withDetailView {
            SettingsItem.Input()
              .bindTo(.maxThumbnailPreviewCacheSize)
              .range(0...Double(Int.max))
              .trailingLabel(.text_MB)
            SettingsItem.Switch()
              .bindTo(.enableThumbnailForRemoteFiles)
            SettingsItem.Input()
              .bindTo(.thumbnailWidth)
              .range(1...2000)
              .trailingLabel(.text_pt)
              .hasDescription()
          }
      }
    }
  }

  private func sectionPIP() -> SettingsSection {
    return section {
      SettingsList(title: .text_PictureinnPicture) {
        SettingsItem.General(title: .text_WhenEnteringPIP)
          .image(name: "pip.enter")
          .withDetailView {
            SettingsItem.PopupButton()
              .bindTo(.windowBehaviorWhenPip, ofType: Preference.WindowBehaviorWhenPip.self)
            SettingsItem.Switch()
              .bindTo(.pauseWhenPip)
          }
        SettingsItem.Switch()
          .image(name: "pip.swap")
          .bindTo(.togglePipByMinimizingWindow)
          .withDetailView {
            SettingsItem.Switch()
              .bindTo(.togglePipByMinimizingWindowForVideoOnly)
          }
      }
    }
  }

  private func sectionAccessibility() -> SettingsSection {
    return section {
      SettingsList(title: .text_Accessibility) {
        SettingsItem.Switch()
          .image(name: "accessibility")
          .bindTo(.disableAnimations)
          .hasDescription()
          .withHelpLink(AppData.disableAnimationsHelpLink)
      }
    }
  }
}


fileprivate let SizeWidthTag = 0
fileprivate let SizeHeightTag = 1
fileprivate let UnitPointTag = 0
fileprivate let UnitPercentTag = 1
fileprivate let SideLeftTag = 0
fileprivate let SideRightTag = 1
fileprivate let SideTopTag = 0
fileprivate let SideBottomTag = 1


fileprivate class GeometryBindings: NSObject {
  private let key = Preference.Key.initialWindowSizePosition
  private let prefObserver = Preference.Observer()

  var windowSizeSwitch: SettingsItem.Switch!
  var windowSizeSide: NSPopUpButton!
  var windowSizeValue: NSTextField!
  var windowSizeUnit: NSPopUpButton!

  var windowPosSwitch: SettingsItem.Switch!
  var windowPosXAnchor: NSPopUpButton!
  var windowPosXOffset: NSTextField!
  var windowPosXUnit: NSPopUpButton!
  var windowPosYAnchor: NSPopUpButton!
  var windowPosYOffset: NSTextField!
  var windowPosYUnit: NSPopUpButton!

  override init() {
    super.init()
    prefObserver.add(key) { [unowned self] _ in
      updateControls()
    }
  }

  func initControl<T>(_ keyPath: ReferenceWritableKeyPath<GeometryBindings, T?>, _ value: T) {
    self[keyPath: keyPath] = value
    if let value = value as? SettingsItem.Switch {
      value.stateChangeCallback = { [weak self] _ in
        self?.updateGeometry(value)
      }
    } else if let value = value as? NSControl {
      value.target = self
      value.action = #selector(updateGeometry(_:))
    }
  }

  @objc func updateGeometry(_ sender: AnyObject) {
    var geometry = ""
    if windowSizeSwitch.nsSwitch.state == .on {
      geometry += windowSizeSide.selectedTag() == SizeWidthTag ? "" : "x"
      geometry += windowSizeValue.stringValue
      geometry += windowSizeUnit.selectedTag() == UnitPointTag ? "" : "%"
    }
    if windowPosSwitch.nsSwitch.state == .on {
      geometry += windowPosXAnchor.selectedTag() == SideLeftTag ? "+" : "-"
      geometry += windowPosXOffset.stringValue
      geometry += windowPosXUnit.selectedTag() == UnitPointTag ? "" : "%"
      geometry += windowPosYAnchor.selectedTag() == SideBottomTag ? "+" : "-"
      geometry += windowPosYOffset.stringValue
      geometry += windowPosYUnit.selectedTag() == UnitPointTag ? "" : "%"
    }
    Preference.set(geometry, for: .initialWindowSizePosition)
  }

  func updateControls() {
    let geometryString = Preference.string(for: .initialWindowSizePosition) ?? ""
    if let geometry = GeometryDef.parse(geometryString) {
      // size
      if let h = geometry.h {
        windowSizeSwitch.setIsOn(true)
        windowSizeSide.selectItem(withTag: SizeHeightTag)
        let isPercent = h.hasSuffix("%")
        windowSizeUnit.selectItem(withTag: isPercent ? UnitPercentTag : UnitPointTag)
        windowSizeValue.stringValue = isPercent ? String(h.dropLast()) : h
      } else if let w = geometry.w {
        windowSizeSwitch.setIsOn(true)
        windowSizeSide.selectItem(withTag: SizeWidthTag)
        let isPercent = w.hasSuffix("%")
        windowSizeUnit.selectItem(withTag: isPercent ? UnitPercentTag : UnitPointTag)
        windowSizeValue.stringValue = isPercent ? String(w.dropLast()) : w
      } else {
        windowSizeSwitch.setIsOn(false)
      }
      // position
      if let x = geometry.x, let xSign = geometry.xSign, let y = geometry.y, let ySign = geometry.ySign {
        windowPosSwitch.setIsOn(true)
        let xIsPercent = x.hasSuffix("%")
        windowPosXAnchor.selectItem(withTag: xSign == "+" ? SideLeftTag : SideRightTag)
        windowPosXOffset.stringValue = xIsPercent ? String(x.dropLast()) : x
        windowPosXUnit.selectItem(withTag: xIsPercent ? UnitPercentTag : UnitPointTag)
        let yIsPercent = y.hasSuffix("%")
        windowPosYAnchor.selectItem(withTag: ySign == "+" ? SideBottomTag : SideTopTag)
        windowPosYOffset.stringValue = yIsPercent ? String(y.dropLast()) : y
        windowPosYUnit.selectItem(withTag: yIsPercent ? UnitPercentTag : UnitPointTag)
      } else {
        windowPosSwitch.setIsOn(false)
      }
    } else {
      windowSizeSwitch.setIsOn(false)
      windowPosSwitch.setIsOn(false)
    }
  }
}


fileprivate class WindowInitialSizeView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()
  let container: NSView
  let view: NSStackView

  lazy var popupButtonDim: NSPopUpButton = ui.popupButton([
    (.text_Width, 0), (.text_Height, 1)
  ])

  lazy var popupButtonUnit: NSPopUpButton = ui.popupButton([
    (.text_point, 0), (.text_ofScreen, 1)
  ])

  lazy var textField: NSTextField = ui.textInput(value: "1280", width: Tokens.Size.textInputWidth)

  init(geometryBindings: GeometryBindings) {
    self.container = NSView()
    self.view = NSStackView()
    self.view.translatesAutoresizingMaskIntoConstraints = false
    self.view.orientation = .horizontal
    self.view.alignment = .firstBaseline

    view.addArrangedSubview(popupButtonDim)
    view.addArrangedSubview(textField)
    view.addArrangedSubview(popupButtonUnit)

    geometryBindings.initControl(\.windowSizeSide, popupButtonDim)
    geometryBindings.initControl(\.windowSizeValue, textField)
    geometryBindings.initControl(\.windowSizeUnit, popupButtonUnit)

    container.addSubview(view)
    view.padding(.bottom(Tokens.Space.n8), .top(Tokens.Space.n0), .leading(SettingsSubList.indent), .trailing(Tokens.Space.n0))
  }

  func makeView() -> NSView {
    return container
  }
}


fileprivate class WindowInitialPositionView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()
  let container: NSView
  let view: NSStackView

  lazy var popupButtonXPos: NSPopUpButton = ui.popupButton([
    (.text_top, 0), (.text_bottom, 1)
  ])

  lazy var popupButtonYPos: NSPopUpButton = ui.popupButton([
    (.text_left, 0), (.text_right, 1)
  ])

  lazy var popupButtonXUnit: NSPopUpButton = ui.popupButton([
    (.text_point, 0), (.text_ofScreen, 1)
  ])

  lazy var popupButtonYUnit: NSPopUpButton = ui.popupButton([
    (.text_point, 0), (.text_ofScreen, 1)
  ])

  lazy var textFieldX: NSTextField = ui.textInput(value: "20", width: Tokens.Size.textInputWidth)

  lazy var textFieldY: NSTextField = ui.textInput(value: "20", width: Tokens.Size.textInputWidth)

  init(geometryBindings: GeometryBindings) {
    self.container = NSView()
    self.view = NSStackView()
    self.view.translatesAutoresizingMaskIntoConstraints = false
    self.view.orientation = .vertical
    self.view.alignment = .leading

    view.addArrangedSubview(
      ui.hStack(align: .firstBaseline, ui.image("arrow.left.to.line"), ui.smallLabel(bindTo: .text_XOffset), textFieldX, popupButtonXUnit)
    )
    view.addArrangedSubview(
      ui.hStack(align: .firstBaseline, ui.space(width: Tokens.Size.n16), ui.smallLabel(bindTo: .text_toThe), popupButtonXPos, ui.smallLabel(bindTo: .text_sideOfTheScreen))
    )
    view.addArrangedSubview(
      ui.hStack(align: .firstBaseline, ui.image("arrow.up.to.line"), ui.smallLabel(bindTo: .text_YOffset), textFieldY, popupButtonYUnit)
    )
    view.addArrangedSubview(
      ui.hStack(align: .firstBaseline, ui.space(width: Tokens.Size.n16), ui.smallLabel(bindTo: .text_toThe), popupButtonYPos, ui.smallLabel(bindTo: .text_sideOfTheScreen))
    )

    container.addSubview(view)
    view.padding(.bottom(Tokens.Space.n8), .top(Tokens.Space.n0), .leading(SettingsSubList.indent), .trailing(Tokens.Space.n0))

    geometryBindings.initControl(\.windowPosXAnchor, popupButtonXPos)
    geometryBindings.initControl(\.windowPosXUnit, popupButtonXUnit)
    geometryBindings.initControl(\.windowPosXOffset, textFieldX)
    geometryBindings.initControl(\.windowPosYAnchor, popupButtonYPos)
    geometryBindings.initControl(\.windowPosYUnit, popupButtonYUnit)
    geometryBindings.initControl(\.windowPosYOffset, textFieldY)
  }

  func makeView() -> NSView {
    return container
  }
}


fileprivate class ResizeWindowView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()

  let view: NSView

  init() {
    self.view = NSView()
    let buttons = ui.radioGroup(.resizeWindowTiming, size: .regular, [
      (.text_AlwaysWhenPlaying, 0), (.text_WhenMediaIsOpenedManually, 1), (.text_DoNotResize, 2)
    ])

    buttons.forEach {
      view.addSubview($0)
      $0.padding(.leading(Tokens.Space.n20))
    }
    SettingsUIHelper.vEquallySpaced(buttons, 8, top: 0, bottom: 12)
  }

  func makeView() -> NSView {
    return view
  }
}


fileprivate class OSCLayoutView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()

  let view: NSView
  let imageViews: [NSImageView]

  init() {
    self.view = NSView()
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false

    self.imageViews = [
      NSImageView(image: .sf("osc_bottom_figure")!),
      NSImageView(image: .sf("osc_top_figure")!),
      NSImageView(image: .sf("osc_bottom_figure")!),
    ]

    imageViews.forEach { iv in
      iv.wantsLayer = true
      iv.layer?.borderWidth = Tokens.Stroke.strong
      iv.layer?.borderColor = Tokens.Palette.separator.nsColor.cgColor
      iv.layer?.cornerRadius = Tokens.Radius.n6
      iv.layer?.masksToBounds = true
      iv.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(iv)
      iv.padding(.top(Tokens.Space.n4)).size(width: Tokens.Size.imagePreviewWidth, height: Tokens.Size.imagePreviewHeight)
    }
    SettingsUIHelper.hEquallySpaced(imageViews, 8, leading: SettingsSubList.indent, trailing: 8)

    let buttons = ui.radioGroup(.oscPosition, size: .regular, [
      (.oscPositionItem0, 0), (.oscPositionItem1, 1), (.oscPositionItem2, 2)
    ])

    for (i, btn) in buttons.enumerated() {
      container.addSubview(btn)
      btn.spacing(.top(Tokens.Space.n8), to: imageViews[i]).padding(.bottom(Tokens.Space.n12))
        .center(.x, with: imageViews[i])
    }

    view.addSubview(container)
    container.padding(.vertical).center(.x)
  }

  func makeView() -> NSView {
    return view
  }
}


private class OSCToolbarView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()

  let view: NSView
  let oscToolbarStackView: NSStackView
  let customizeButton: NSButton
  private let toolbarSettingsSheetController = PrefOSCToolbarSettingsSheetController()

  init() {
    self.view = NSView()
    self.oscToolbarStackView = NSStackView()
    self.customizeButton = NSButton(title: ui.localized(.text_Customize), target: nil, action: nil)
  }

  private func updateOSCToolbarButtons() {
    oscToolbarStackView.views.forEach { oscToolbarStackView.removeView($0) }
    for buttonType in PrefUIViewController.oscToolbarButtons {
      let button = NSButton()
      OSCToolbarButton.setStyle(of: button, buttonType: buttonType)
      oscToolbarStackView.addView(button, in: .trailing)
      // Button is actually disabled so that its mouseDown goes to its superview instead
      button.isEnabled = false
      // But don't gray it out
      (button.cell! as! NSButtonCell).imageDimsWhenDisabled = false
    }
  }

  @objc func customizeOSCToolbarAction(_ sender: NSButton!) {
    toolbarSettingsSheetController.currentItemsView?.initItems(fromItems: PrefUIViewController.oscToolbarButtons)
    toolbarSettingsSheetController.currentButtonTypes = PrefUIViewController.oscToolbarButtons
    view.window?.beginSheet(toolbarSettingsSheetController.window!) { response in
      guard response == .OK else { return }
      let newItems = self.toolbarSettingsSheetController.currentButtonTypes
      let array = newItems.map { $0.rawValue }
      Preference.set(array, for: .controlBarToolbarButtons)
      self.updateOSCToolbarButtons()
    }
  }

  func makeView() -> NSView {
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false

    oscToolbarStackView.translatesAutoresizingMaskIntoConstraints = false
    oscToolbarStackView.orientation = .horizontal
    oscToolbarStackView.distribution = .gravityAreas
    oscToolbarStackView.spacing = 0

    let box = NSBox()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.boxType = .primary
    box.titlePosition = .noTitle
    box.contentViewMargins = .zero
    box.addSubview(oscToolbarStackView)
    oscToolbarStackView.padding(.vertical, .leading(greaterThan: 0), .trailing(Tokens.Space.n0))
    container.addSubview(box)
    box.padding(.top, .bottom(Tokens.Space.n8))
    box.widthAnchor
      .constraint(equalTo: box.heightAnchor, multiplier: 5).isActive = true

    customizeButton.target = self
    customizeButton.action = #selector(customizeOSCToolbarAction(_:))
    customizeButton.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(customizeButton)
    customizeButton.center(.y, with: box)
    SettingsUIHelper.hEquallySpaced([box, customizeButton], 8, leading: SettingsSubList.indent, trailing: 8)

    view.addSubview(container)
    container.padding(.vertical).center(.x)
    updateOSCToolbarButtons()
    return view
  }
}
