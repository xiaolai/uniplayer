//
//  SettingsPageAudio.swift
//  uniplayer
//
//  Created by Hechen Li on 6/15/25.
//  Copyright © 2025 lhc. All rights reserved.
//

fileprivate let ui = SettingsUIHelper.sharedUI


class SettingsPageAudio: SettingsPage {
  private lazy var audioOutputDeviceView: AudioOutputDeviceView = AudioOutputDeviceView()

  override var identifier: String {
    "audio"
  }

  override var title: String {
    return NSLocalizedString("sidebar.audio", comment: "Audio")
  }

  override var image: NSImage {
    return .sf("waveform", withConfiguration: symbolConfiguration)!
  }

  override var localizationTable: String {
    "SettingsAudioLocalizable"
  }

  override func content() -> [SettingsSection] {
    return sections {
      sectionHardware()
      sectionVolume()
      sectionOther()
    }
  }

  private func sectionHardware() -> SettingsSection {
    return section {
      SettingsList(title: .text_Hardware) {
        SettingsItem.Input(title: .videoThreadsLabel)
          .image(name: "number")
          .bindTo(.audioThreads)
          .range(0...16)
          .hasDescription(content: .videoThreadsDesc)
        SettingsItem.General(title: .audioDriverEnableAVFoundationLabel)
          .image(name: "waveform")
          .withHelpLink(AppData.mpvManualLink.appending("/#audio-output-drivers-coreaudio"))
          .withDetailView(
            SettingsAccessory.Selection()
              .bindTo(.audioDriverEnableAVFoundation, ofType: AudioDriver.self)
              .customTransformer(({ $0 == 1 }, { val in
                if let val = val as? Bool, val {
                  return 1
                }
                return 0
              }))
          )
      }

      SettingsList {
        SettingsItem.General(title: .preferredAudioDeviceLabel)
          .image(name: "hifispeaker.and.homepod")
          .withDetailView(audioOutputDeviceView)
        SettingsItem.General(title: .text_SPDIFOutput)
          .image(name: "audio.jack.stereo")
          .hasDescription(content: .text_SPDIFOutputWarning)  // For why warning, see issue #6251.
          .withHelpLink(AppData.mpvManualLink.appending("/#options-audio-spdif"))
          .withExpandingDetailView {
            SettingsItem.Switch()
              .bindTo(.spdifAC3)
            SettingsItem.Switch()
              .bindTo(.spdifDTS)
            SettingsItem.Switch()
              .bindTo(.spdifDTSHD)
            SettingsItem.Switch()
              .bindTo(.spdifEAC3)
            SettingsItem.Switch()
              .bindTo(.spdifTRUEHD)
          }
      }
    }
  }

  private func sectionVolume() -> SettingsSection {
    return section {
      SettingsList(title: .text_Volume) {
        SettingsItem.SwitchWithInput()
          .image(name: "speaker.wave.3")
          .labelKey(.enableInitialVolume)
          .bindInputTo(.initialVolume)
          .bindSwitchTo(.enableInitialVolume)
          .range(0...1000) // mpv option is a float, but UniPlayer uses integers for volume.
        SettingsItem.Input()
          .bindTo(.maxVolume)
          .range(100...1000)
          .hasDescription()
      }

      SettingsList {
        SettingsItem.PopupButton()
          .image(name: "speaker.plus")
          .bindTo(.replayGain, ofType: Preference.ReplayGainOption.self)
          .disableSubListOnTag(0)
          .hasDescription()
          .withHelpLink(AppData.mpvManualLink.appending("/#options-replaygain"))
          .withDetailView {
            SettingsItem.Input()
              .bindTo(.replayGainPreamp)
              .range(-150...150)
              .trailingLabel(.text_dB)
              .hasDescription()
            SettingsItem.Switch()
              .bindTo(.replayGainClip)
              .hasDescription()
          }
        SettingsItem.Input()
          .image(name: "square.dotted")
          .bindTo(.replayGainFallback)
          .range(-200...60)
          .trailingLabel(.text_dB)
          .hasDescription()
      }
    }
  }

  private func sectionOther() -> SettingsSection {
    return section {
      SettingsList(title: .text_AudioOther) {
        SettingsItem.General(title: .gaplessAudioLabel)
          .image(name: "custom.waveform.2.arrow.trianglehead.2.clockwise.rotate.90")
          .withHelpLink(AppData.mpvManualLink.appending("/#options-gapless-audio"))
          .withDetailView(
            SettingsAccessory.Selection()
              .bindTo(.gaplessAudio, ofType: Preference.GaplessAudioOption.self)
          )
      }

      SettingsList {
        SettingsItem.General(title: .text_PreferredLanguage)
          .image(name: "character.book.closed")
          .withDetailView(
            SettingsAccessory.LanguageSelector()
              .bind(to: .audioLanguage)
          )
      }
    }
  }
}


fileprivate enum AudioDriver: Int, InitializingFromKey, CaseIterable {
  case coreAudio = 0
  case avFoundation

  static var defaultValue = AudioDriver.coreAudio

  init?(key: Preference.Key) {
    self.init(rawValue: Preference.integer(for: key))
  }

  var description: String {
    switch self {
    case .coreAudio: "coreAudio"
    case .avFoundation: "avFoundation"
    }
  }
}


fileprivate class AudioOutputDeviceView: SettingsContainer {
  lazy var itemID = SettingsContainerUUID.next()

  let view: NSView
  let audioDevicePopUp: NSPopUpButton

  init() {
    self.view = NSView()
    self.audioDevicePopUp = NSPopUpButton()
  }

  func makeView() -> NSView {
    audioDevicePopUp.translatesAutoresizingMaskIntoConstraints = false
    audioDevicePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    audioDevicePopUp.removeAllItems()

    let selection = MPVAudioDevice.currentSelection()
    for device in selection.devices {
      audioDevicePopUp.addItem(withTitle: device.description)
      audioDevicePopUp.lastItem!.representedObject = device
      if device.name == selection.selected.name {
        audioDevicePopUp.select(audioDevicePopUp.lastItem!)
      }
    }

    audioDevicePopUp.target = self
    audioDevicePopUp.action = #selector(audioDeviceAction)

    view.addSubview(audioDevicePopUp)
    audioDevicePopUp.padding(.top(topConstraintOffset), .bottom(Tokens.Space.n8), .leading(SettingsSubList.indent), .trailing(Tokens.Space.n8))

    return view
  }

  @objc func audioDeviceAction(_ sender: Any) {
    let device = audioDevicePopUp.selectedItem!.representedObject as! MPVAudioDevice
    Preference.set(device.name, for: .audioDevice)
    Preference.set(device.desc, for: .audioDeviceDesc)
  }
}
