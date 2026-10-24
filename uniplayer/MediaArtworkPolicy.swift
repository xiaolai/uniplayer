//
//  MediaArtworkPolicy.swift
//  uniplayer
//
//  Release-1 artwork policy: only a known, readable local file may ask the
//  existing poster cache for an image. A mounted share, a missing row or a
//  legacy URL never starts a remote Quick Look/frame probe.
//

import Foundation

enum MediaArtworkPolicy {
  static func shouldLoadArtwork(for media: CatalogMedia) -> Bool {
    guard media.presence != .missing,
          media.rootKind == .local,
          let url = media.url else { return false }
    return url.isFileURL
  }

  private static let cacheLock = NSLock()
  /// Mount path to the observed file-system type and verdict. The type is
  /// compared on every lookup, so a mount replaced by a share at the same path
  /// is re-evaluated rather than reusing the old answer.
  private static var mounts: [String: (type: String, local: Bool)] = [:]
  private static let networkFileSystems: Set<String> = [
    "smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp",
  ]

  /// True when the URL lives on a local file system. This is the shared gate
  /// for every poster request, including the legacy views that have no
  /// `CatalogMedia` to consult: artwork for a mounted share is never probed.
  /// Call it off the main thread; `statfs` on a blocked mount may block.
  static func allowsProbe(for url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var info = statfs()
    guard statfs(url.standardizedFileURL.path, &info) == 0 else { return false }
    let mount = string(fromCCharTuple: info.f_mntonname, capacity: Int(MNAMELEN))
    let type = string(fromCCharTuple: info.f_fstypename, capacity: Int(MNAMELEN))
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let cached = mounts[mount], cached.type == type { return cached.local }
    let local = !networkFileSystems.contains(type)
    mounts[mount] = (type, local)
    return local
  }

  private static func string<T>(fromCCharTuple tuple: T, capacity: Int) -> String {
    withUnsafePointer(to: tuple) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
        String(cString: $0)
      }
    }
  }
}
