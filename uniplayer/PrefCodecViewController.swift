//
//  PrefCodecViewController.swift
//  uniplayer
//
//  Created by lhc on 27/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

@objcMembers
class PrefCodecViewController: PreferenceViewController, PreferenceWindowEmbeddable {

  override var nibName: NSNib.Name {
    return NSNib.Name("PrefCodecViewController")
  }

  var preferenceTabTitle: String {
    return NSLocalizedString("preference.video_audio", comment: "Codec")
  }

  var preferenceTabImage: NSImage {
    return .sf("play.rectangle.on.rectangle", "photo.tv", withConfiguration: symbolConfiguration)!
  }

  override var sectionViews: [NSView] {
    return [sectionVideoView, sectionAudioView, sectionReplayGainView]
  }

  @IBOutlet var sectionVideoView: NSView!
  @IBOutlet var sectionAudioView: NSView!
  @IBOutlet var sectionReplayGainView: NSView!
  
  @IBOutlet weak var audioDriverExperimentalIndicator: NSImageView!

  @IBOutlet weak var spdifAC3Btn: NSButton!
  @IBOutlet weak var spdifDTSBtn: NSButton!
  @IBOutlet weak var spdifDTSHDBtn: NSButton!
  @IBOutlet weak var hwdecDescriptionTextField: NSTextField!
  @IBOutlet weak var audioLangTokenField: LanguageTokenField!

  @IBOutlet weak var audioDevicePopUp: NSPopUpButton!

  @IBOutlet weak var gaplessAudioDescriptionTextField: NSTextField!

  @IBOutlet weak var enableToneMappingBtn: NSButton!
  @IBOutlet weak var toneMappingTargetPeakTextField: NSTextField!
  @IBOutlet weak var toneMappingAlgorithmPopUpBtn: NSPopUpButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    audioLangTokenField.commaSeparatedValues = Preference.string(for: .audioLanguage) ?? ""
    updateHwdecDescription()
    updateGaplessAudioDescription()
    updateToneMappingUI()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    
    audioDriverExperimentalIndicator.image = NSImage.sf("flask.fill")
    updateAudioDevicePopUp()

    // The list of audio devices changes based on the audio driver setting.
    UserDefaults.standard.addObserver(self, forKeyPath: PK.audioDriverEnableAVFoundation.rawValue,
                                      options: .new, context: nil)
  }

  @IBAction func audioDeviceAction(_ sender: Any) {
    let device = audioDevicePopUp.selectedItem!.representedObject as! MPVAudioDevice
    Preference.set(device.name, for: .audioDevice)
    Preference.set(device.desc, for: .audioDeviceDesc)
  }

  @IBAction func spdifBtnAction(_ sender: AnyObject) {
    var spdif: [String] = []
    if spdifAC3Btn.state == .on { spdif.append("ac3") }
    if spdifDTSBtn.state == .on { spdif.append("dts") }
    if spdifDTSHDBtn.state == .on { spdif.append("dts-hd") }
    let spdifString = spdif.joined(separator: ",")
    PlayerCore.playerCores.forEach { $0.mpv.setString(MPVOption.Audio.audioSpdif, spdifString) }
  }

  @IBAction func hwdecAction(_ sender: AnyObject) {
    updateHwdecDescription()
  }

  @IBAction func preferredLanguageAction(_ sender: LanguageTokenField) {
    let csv = sender.commaSeparatedValues
    if Preference.string(for: .audioLanguage) != csv {
      Logger.log("Saving \(Preference.Key.audioLanguage.rawValue): \"\(csv)\"", level: .verbose)
      Preference.set(csv, for: .audioLanguage)
    }
  }

  /// Update the list of audio devices.
  ///
  /// The list needs to be updated whenever the configured audio output driver changes as mpv audio devices are tied to a specific
  /// audio output driver. The selected audio device may need to be updated to one using the currently configured audio output driver.
  private func updateAudioDevicePopUp() {
    audioDevicePopUp.removeAllItems()
    let selection = MPVAudioDevice.currentSelection()
    for device in selection.devices {
      audioDevicePopUp.addItem(withTitle: device.description)
      audioDevicePopUp.lastItem!.representedObject = device
      if device.name == selection.selected.name {
        audioDevicePopUp.select(audioDevicePopUp.lastItem!)
      }
    }
  }

  private func updateHwdecDescription() {
    let hwdec: Preference.HardwareDecoderOption = Preference.enum(for: .hardwareDecoder)
    hwdecDescriptionTextField.stringValue = hwdec.localizedDescription
  }

  @IBAction func gaplessAudioAction(_ sender: Any) {
    updateGaplessAudioDescription()
  }

  private func updateGaplessAudioDescription() {
    let gaplessAudio: Preference.GaplessAudioOption = Preference.enum(for: .gaplessAudio)
    gaplessAudioDescriptionTextField.stringValue = gaplessAudio.localizedDescription
  }

  // Prefs → UI
  private func updateToneMappingUI() {
    toneMappingTargetPeakTextField.integerValue = Preference.integer(for: .toneMappingTargetPeak)
  }

  @IBAction func toneMappingTargetPeakAction(_ sender: NSTextField) {
    defer {
      updateToneMappingUI()
    }
    let newValue = sender.integerValue
    // constrain to valid mpv values
    let isValueValid = newValue == 0 || (newValue >= 10 && newValue <= 10000)
    guard isValueValid else {
      Utility.showAlert("target_peak.bad_value", arguments: [String(newValue)], sheetWindow: view.window)
      sender.integerValue = Preference.integer(for: .toneMappingTargetPeak)
      return
    }
    Preference.set(newValue, for: .toneMappingTargetPeak)
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey : Any]?,
                             context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath else { return }
    switch keyPath {
    case PK.audioDriverEnableAVFoundation.rawValue:
      updateAudioDevicePopUp()
    default:
      return
    }
  }

  @IBAction func toneMappingHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.toneMappingHelpLink)!)
  }

  @IBAction func targetPeakHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.mpvManualLink.appending("/#options-target-peak"))!)
  }

  @IBAction func algorithmHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.mpvManualLink.appending("/#options-tone-mapping"))!)
  }

  @IBAction func gainAdjustmentHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.mpvManualLink.appending("/#options-replaygain"))!)
  }

  @IBAction func gaplessAudioHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.mpvManualLink.appending("/#options-gapless-audio"))!)
  }

  @IBAction func audioDriverHelpAction(_ sender: Any) {
    NSWorkspace.shared.open(URL(string: AppData.mpvManualLink.appending("/#audio-output-drivers-coreaudio"))!)
  }
}
