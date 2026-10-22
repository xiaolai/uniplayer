//
//  CacheManager.swift
//  uniplayer
//
//  Created by lhc on 28/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class CacheManager {

  static let shared = CacheManager()

  private let queue = DispatchQueue(label: "uniplayer.cache-manager")
  private var jobRunning = false
  private var _needsRefresh = true
  private var cachedContents: [URL]?

  /// Whether the directory snapshot is stale. All access is serialized.
  var needsRefresh: Bool {
    get { queue.sync { _needsRefresh } }
    set { queue.sync { _needsRefresh = newValue } }
  }

  private func cacheFolderContents() -> [URL]? {
    if _needsRefresh, let contents = try? FileManager.default.contentsOfDirectory(
      at: Utility.thumbnailCacheURL,
      includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
      cachedContents = contents
      _needsRefresh = false
    }
    return cachedContents
  }

  func getCacheSize() -> Int {
    queue.sync {
      cacheFolderContents()?.reduce(0) { totalSize, url in
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return totalSize + size
      } ?? 0
    }
  }

  func clearOldCache() {
    queue.sync {
      guard !jobRunning else { return }
      jobRunning = true
      defer { jobRunning = false }

      let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize)
      // If full, delete 50% of max cache.
      let cacheToDelete = maxCacheSize * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue / 2

      guard let contents = cacheFolderContents()?.sorted(by: { url1, url2 in
        let date1 = (try? url1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
        let date2 = (try? url2.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
        return date1.compare(date2) == .orderedAscending
      }) else { return }

      var clearedCacheSize = 0
      for url in contents where clearedCacheSize < cacheToDelete {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        do {
          try FileManager.default.removeItem(at: url)
          clearedCacheSize += size
        } catch {
          Logger.log("Cannot remove cache item \(url.lastPathComponent): \(error.localizedDescription)", level: .warning)
        }
      }

      _needsRefresh = true
    }
  }
}
