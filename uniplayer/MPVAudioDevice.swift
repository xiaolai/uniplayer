//
//  MPVAudioDevice.swift
//  uniplayer
//
//  Created by low-batt on 7/26/25.
//  Copyright © 2025 lhc. All rights reserved.
//

import Foundation

/// A mpv audio device.
///
/// This represents one of the audio devices returned by mpv in the value of the property
/// [audio-device-list](https://mpv.io/manual/stable/#command-interface-audio-device-list) or saved in UniPlayer's
/// settings as the preferred audio device.
struct MPVAudioDevice: CustomStringConvertible {

  /// Human readable free form text describing the audio device.
  let desc: String

  /// `True` if this audio device is not currently connected, false otherwise.
  let isMissing: Bool

  /// Audio API-specific ID.,
  ///
  /// This ID is intended to be passed as the value of the
  /// [--audio-device](https://mpv.io/manual/stable/#options-audio-device) mpv option when selecting this device.
  /// The pseudo device with the name set to `auto` selects the default audio output driver and the default device. With the exception
  /// of that device the `name` starts with a mpv-specific `<driver>/` prefix, tying the device to a specific audio output driver.
  let name: String

  /// A string describing the audio device that is suitable for use as a menu item title.
  var description: String {
    guard isMissing else { return "[\(desc)] \(name)" }
    return "[\(desc) (missing)] \(name)"
  }

  /// Audio output driver required by this audio device (if applicable).
  var driver: String? {
    guard !name.starts(with: "avfoundation/") else { return "avfoundation" }
    guard !name.starts(with: "coreaudio/") else { return "coreaudio" }
    // This is "auto" which corresponds to the default audio output driver and the default device.
    return nil
  }

  /// The `name` (audio API-specific ID) with the `<driver>/` prefix removed.
  private var nameWithoutDriver: String {
    guard let driver else { return name }
    return String(name.suffix(name.count - driver.count - 1))
  }

  /// Construct an audio device.
  ///
  /// The device is given as a dictionary that contains two entries describing the device:
  /// - `name`: Audio API-specific ID, to be passed as the value of the `audio-device` mpv option
  /// - `description`: Human readable free form text describing the audio device
  /// - Parameter device: Dictionary describing the device.
  init(_ device: [String: String]) {
    desc = device["description"]!
    name = device["name"]!
    isMissing = false
  }

  /// Construct an audio device.
  /// - Parameters:
  ///   - desc: Human readable free form text describing the audio device.
  ///   - name: Audio API-specific ID.
  ///   - isMissing: Whether this audio device is currently connected.
  init(desc: String, name: String, isMissing: Bool = false) {
    self.desc = desc
    self.name = name
    self.isMissing = isMissing
  }

  /// Construct an audio device from an existing device, replacing the audio output driver.
  /// - Parameters:
  ///   - device: Audio device to base the new device on.
  ///   - driver: Audio output driver to use in `name`.
  init(_ device: MPVAudioDevice, _ driver: String) {
    self.desc = device.desc
    self.name = "\(driver)/\(device.nameWithoutDriver)"
    isMissing = false
  }
}

extension MPVAudioDevice {

  struct Selection {
    /// The available devices, including a synthetic missing entry when the
    /// configured device is not connected.
    let devices: [MPVAudioDevice]
    /// The device that should be selected in a device list.
    let selected: MPVAudioDevice
  }

  /// Loads the devices for the current audio output driver and resolves the
  /// configured device against them.
  ///
  /// When the configured device belongs to the other output driver, the
  /// equivalent device for the current driver is found and written back to the
  /// preferences. When no equivalent exists the configured device is returned
  /// as a missing entry so the user can see what is still configured.
  static func currentSelection() -> Selection {
    var devices = PlayerCore.active.getAudioDevices()
    let configuredName = Preference.string(for: .audioDevice)!
    if let match = devices.first(where: { $0.name == configuredName }) {
      return Selection(devices: devices, selected: match)
    }

    let description = Preference.string(for: .audioDeviceDesc)!
    let configured = MPVAudioDevice(desc: description, name: configuredName)
    let avfoundationEnabled = Preference.bool(for: PK.audioDriverEnableAVFoundation)
    let invalid = avfoundationEnabled ? "coreaudio" : "avfoundation"
    if configured.driver == invalid {
      let driver = avfoundationEnabled ? "avfoundation" : "coreaudio"
      let replacement = MPVAudioDevice(configured, driver)
      if let match = devices.first(where: { $0.name == replacement.name }) {
        Logger.log("""
            Audio output driver changed to \(driver), changing audio device setting
              from: \(configuredName)
              to: \(replacement.name)
            """)
        Preference.set(replacement.name, for: .audioDevice)
        return Selection(devices: devices, selected: match)
      }
    }

    let missing = MPVAudioDevice(desc: description, name: configuredName, isMissing: true)
    devices.append(missing)
    return Selection(devices: devices, selected: missing)
  }
}
