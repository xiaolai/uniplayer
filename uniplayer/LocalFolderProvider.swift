//
//  LocalFolderProvider.swift
//  uniplayer
//
//  The release-1 provider. It observes local volumes and already-mounted SMB
//  shares through POSIX/Foundation public APIs. macOS owns authentication and
//  the mount lifecycle; this provider never mounts, unmounts, stores or asks
//  for credentials.
//

import Foundation

final class LocalFolderProvider: MediaSourceProvider {
  let kind: MediaSourceKind = .local

  /// A single directory beyond this cap is returned as a partial listing.
  /// Snapshot completeness is false, so absence is never inferred from it.
  static let maxDirectoryEntries = 50_000

  private static let resourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .isPackageKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .isReadableKey,
    .volumeUUIDStringKey,
    .volumeSupportsCaseSensitiveNamesKey,
    .volumeNameKey,
    .volumeIsLocalKey,
  ]

  func observeIdentity(at url: URL) throws -> SourceIdentity {
    let standardized = url.standardizedFileURL
    var info = statfs()
    guard statfs(standardized.path, &info) == 0 else {
      throw Self.mapPOSIXError(errno)
    }

    let fileSystemType = Self.string(fromCCharTuple: info.f_fstypename,
                                     capacity: Int(MFSNAMELEN))
    let mountFrom = Self.string(fromCCharTuple: info.f_mntfromname,
                                capacity: Int(MNAMELEN))
    let mountPoint = Self.string(fromCCharTuple: info.f_mntonname,
                                 capacity: Int(MNAMELEN))

    let isSMB = fileSystemType == "smbfs" || mountFrom.hasPrefix("//")
    let providerKind: MediaSourceKind = isSMB ? .mountedSMB : .local

    let values = try? standardized.resourceValues(forKeys: Self.resourceKeys)
    let volumeUUID = values?.volumeUUIDString
    let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false

    let pathInNamespace: String
    let mountPath: String
    if standardized.path == mountPoint {
      pathInNamespace = ""
      mountPath = mountPoint
    } else if standardized.path.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/") {
      pathInNamespace = String(standardized.path.dropFirst(mountPoint.count))
      mountPath = mountPoint
    } else {
      pathInNamespace = standardized.path
      mountPath = "/"
    }

    let endpoint = Self.sanitizedEndpoint(mountFrom: mountFrom, isSMB: isSMB)
    let fsid = String(format: "%08x%08x",
                      UInt32(bitPattern: info.f_fsid.val.0),
                      UInt32(bitPattern: info.f_fsid.val.1))
    // A volume UUID is stable across remounts. Without one, the combination of
    // filesystem type and mount source is still observed rather than guessed,
    // but SMB identity stays unverified so absence is never automatic.
    let volumeIdentity = volumeUUID ?? (fileSystemType + ":" + fsid)
    let verified = volumeUUID != nil || !isSMB

    let namespace = SourceNamespace(
      kind: providerKind,
      volumeIdentity: volumeIdentity,
      fileSystemType: fileSystemType,
      endpointLabel: endpoint,
      accountContextLabel: nil)

    return SourceIdentity(
      namespace: namespace,
      pathInNamespace: pathInNamespace,
      comparison: ComparisonSemantics(caseSensitive: caseSensitive,
                                       unicodeNormalizing: !isSMB),
      mountPath: mountPath,
      isVerified: verified)
  }

  func listDirectory(at url: URL, generation: UInt64) throws -> DirectoryListing {
    let keys: [URLResourceKey] = [
      .isDirectoryKey,
      .isSymbolicLinkKey,
      .isPackageKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    } catch {
      throw Self.mapCocoaError(error)
    }

    var entries: [DirectoryEntry] = []
    entries.reserveCapacity(contents.count)
    var metadataComplete = true
    for item in contents {
      let name = item.lastPathComponent
      if name == ".DS_Store" || name.hasPrefix(".") { continue }
      let values: URLResourceValues
      do {
        values = try item.resourceValues(forKeys: Set(keys))
      } catch {
        // An unreadable entry could be a directory. Calling it a file would
        // invent a media row and hide a directory from reconciliation, so the
        // listing becomes incomplete instead: absence is never derived from it.
        metadataComplete = false
        continue
      }
      let symbolic = values.isSymbolicLink ?? false
      let package = values.isPackage ?? false
      // Packages and bundles are not media containers in release 1.
      if package { continue }
      let directory = (values.isDirectory ?? false) && !symbolic
      entries.append(DirectoryEntry(
        url: item,
        name: name,
        isDirectory: directory,
        isSymbolicLink: symbolic,
        isPackage: package,
        size: values.fileSize.map(Int64.init),
        modified: values.contentModificationDate))
    }

    entries.sort { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    let complete = metadataComplete && entries.count <= Self.maxDirectoryEntries
    if !complete {
      entries = Array(entries.prefix(Self.maxDirectoryEntries))
    }

    return DirectoryListing(
      url: url,
      entries: entries,
      isComplete: complete,
      observedAt: Date(),
      generation: generation)
  }

  func stat(at url: URL) throws -> FileStat {
    do {
      let values = try url.resourceValues(forKeys: Self.resourceKeys)
      return FileStat(
        url: url,
        isDirectory: values.isDirectory ?? false,
        isSymbolicLink: values.isSymbolicLink ?? false,
        isPackage: values.isPackage ?? false,
        size: values.fileSize.map(Int64.init),
        modified: values.contentModificationDate,
        isReadable: values.isReadable ?? true)
    } catch {
      throw Self.mapCocoaError(error)
    }
  }

  // MARK: - Helpers

  private static func sanitizedEndpoint(mountFrom: String, isSMB: Bool) -> String? {
    // A local volume's display name is mutable and therefore is not part of
    // its identity. Only a mounted share's server/share label is stable
    // enough to record here, and even that is a hint.
    guard isSMB else { return nil }
    var value = mountFrom
    if value.hasPrefix("//") {
      value.removeFirst(2)
    }
    // Strip a user/account prefix. Passwords are never part of a mount source
    // on macOS, but drop any userinfo defensively.
    if let at = value.firstIndex(of: "@") {
      value = String(value[value.index(after: at)...])
    }
    if let colon = value.firstIndex(of: ":") {
      value = String(value[value.index(after: colon)...])
    }
    return value.isEmpty ? nil : value
  }

  private static func string<T>(fromCCharTuple tuple: T, capacity: Int) -> String {
    withUnsafePointer(to: tuple) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
        String(cString: $0)
      }
    }
  }

  private static func mapPOSIXError(_ code: Int32) -> MediaSourceError {
    switch code {
    case ENOENT, ENOTDIR: return .notFound
    case EACCES, EPERM: return .permissionDenied
    case ETIMEDOUT: return .timedOut
    case ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH: return .offline
    default: return .unreadable
    }
  }

  private static func mapCocoaError(_ error: Error) -> MediaSourceError {
    let nsError = error as NSError
    switch nsError.code {
    case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
      return .notFound
    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
      return .permissionDenied
    case NSFileReadUnknownError:
      return .unreadable
    default:
      if nsError.domain == NSPOSIXErrorDomain {
        return mapPOSIXError(Int32(nsError.code))
      }
      return .unreadable
    }
  }
}
