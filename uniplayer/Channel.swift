//
//  Channel.swift
//  uniplayer
//
//  Web channels shown in the library sidebar. A channel is a named URL; its
//  cookies and local storage live in the persistent WebKit data store.
//

import Combine
import Foundation

struct Channel: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var url: URL
  var symbol: String

  static let presets: [Channel] = [
    Channel(
      id: "amazon",
      name: "Amazon Prime Video",
      url: URL(string: "https://www.primevideo.com/")!,
      symbol: "shippingbox.fill"),
    Channel(
      id: "netflix",
      name: "Netflix",
      url: URL(string: "https://www.netflix.com/browse")!,
      symbol: "n.square.fill"),
  ]

  /// Builds a channel from user input, or returns `nil` when the URL is not
  /// an HTTP(S) URL with a host.
  static func make(id: String = UUID().uuidString, name: String, urlString: String) -> Channel? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = validatedURL(urlString) else { return nil }
    let finalName = trimmedName.isEmpty ? (url.host ?? url.absoluteString) : trimmedName
    return Channel(id: id, name: finalName, url: url, symbol: "globe")
  }

  static func validatedURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty else {
      return nil
    }
    components.scheme = scheme
    return components.url
  }
}

/// Persists the channel list next to UniPlayer's other application support
/// files. The store seeds the two preset channels only when no file exists;
/// an intentionally empty file stays empty.
final class ChannelStore: ObservableObject {
  static let shared = ChannelStore()

  @Published private(set) var channels: [Channel] = []

  private let fileURL: URL
  private let fileManager = FileManager.default

  init(fileURL: URL = Utility.appSupportDirUrl.appendingPathComponent("channels.json")) {
    self.fileURL = fileURL
    load()
  }

  func channel(id: String) -> Channel? {
    channels.first { $0.id == id }
  }

  @discardableResult
  func add(name: String, urlString: String) -> Channel? {
    guard let channel = Channel.make(name: name, urlString: urlString) else { return nil }
    channels.append(channel)
    save()
    return channel
  }

  @discardableResult
  func update(_ channel: Channel) -> Bool {
    guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return false }
    var updated = channel
    updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if updated.name.isEmpty {
      updated.name = updated.url.host ?? updated.url.absoluteString
    }
    channels[index] = updated
    save()
    return true
  }

  func remove(id: String) {
    let oldCount = channels.count
    channels.removeAll { $0.id == id }
    if channels.count != oldCount {
      save()
    }
  }

  private func load() {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      channels = Channel.presets
      save()
      return
    }

    do {
      let data = try Data(contentsOf: fileURL)
      channels = try JSONDecoder().decode([Channel].self, from: data)
    } catch {
      Logger.log("Cannot read channel list at \(fileURL.path): \(error.localizedDescription)", level: .error)
      channels = Channel.presets
    }
  }

  private func save() {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(channels)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Logger.log("Cannot save channel list at \(fileURL.path): \(error.localizedDescription)", level: .error)
    }
  }
}
