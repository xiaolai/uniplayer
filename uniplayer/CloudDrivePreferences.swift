//
//  CloudDrivePreferences.swift
//  uniplayer
//
//  Cloud-drive playback is opt-in. Nothing is injected into a drive page
//  until the feature is enabled, and a page host can be excluded on its own.
//

import AppKit
import Foundation
import SwiftUI

enum CloudDrivePreferences {
  static let enabledKey = "clouddrive.enabled.v1"
  static let disabledHostsKey = "clouddrive.disabledHosts.v1"
  static let changed = Notification.Name("CloudDriveSettingsChanged")

  static var enabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: enabledKey) != nil else { return false }
    return defaults.bool(forKey: enabledKey)
  }

  static var disabledHosts: [String] {
    UserDefaults.standard.stringArray(forKey: disabledHostsKey) ?? []
  }

  static func allowed(host: String) -> Bool {
    !disabledHosts.contains(host.lowercased())
  }

  static func setEnabled(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: enabledKey)
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func setAllowed(_ allowed: Bool, host: String) {
    let key = host.lowercased()
    guard !key.isEmpty else { return }
    var hosts = disabledHosts
    if allowed {
      hosts.removeAll { $0 == key }
    } else if !hosts.contains(key) {
      hosts.append(key)
    }
    UserDefaults.standard.set(hosts, forKey: disabledHostsKey)
    NotificationCenter.default.post(name: changed, object: nil)
  }
}

struct CloudDriveSettingsContent: View {
  @AppStorage(CloudDrivePreferences.enabledKey) private var enabled = false
  @State private var disabledHosts = Set(CloudDrivePreferences.disabledHosts)

  private var hosts: [String] {
    Set(ChannelStore.shared.channels.compactMap { channel -> String? in
      guard CloudDrives.provider(forPageURL: channel.url) != nil else { return nil }
      return channel.url.host?.lowercased()
    }).sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n12) {
      Toggle("Enable Cloud-Drive Playback (Preview)", isOn: $enabled)
        .onChange(of: enabled) { _, _ in
          NotificationCenter.default.post(name: CloudDrivePreferences.changed, object: nil)
        }
      Text("Adds Play from Drive to a signed-in drive channel. The download address is requested only when you choose the action; the drive's own page stays in charge of authentication. Only Quark has an adapter so far; other drives stay hidden until their checks pass.")
        .font(Tokens.Typography.caption.font)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
      ForEach(hosts, id: \.self) { host in
        Toggle("Show the action on \(host)", isOn: binding(for: host))
      }
      if hosts.isEmpty {
        Text("Add a supported drive channel in the library sidebar first.")
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textSecondary.color)
      }
    }
  }

  private func binding(for host: String) -> Binding<Bool> {
    Binding(
      get: { !disabledHosts.contains(host) },
      set: { allowed in
        if allowed { disabledHosts.remove(host) } else { disabledHosts.insert(host) }
        UserDefaults.standard.set(Array(disabledHosts), forKey: CloudDrivePreferences.disabledHostsKey)
        NotificationCenter.default.post(name: CloudDrivePreferences.changed, object: nil)
      })
  }
}

/// Settings pages take an `NSView`; this hosts the SwiftUI content the same
/// way the torrent settings page does.
final class CloudDriveSettingsView: NSView {
  private let host = NSHostingView(rootView: CloudDriveSettingsContent())

  init() {
    super.init(frame: .zero)
    addSubview(host)
    host.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
