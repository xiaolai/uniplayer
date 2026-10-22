//
//  UtilityActions.swift
//  uniplayer
//
//  Side-effecting operations shared by the current settings window and the
//  legacy preferences window.
//

import Cocoa
import UniformTypeIdentifiers

enum UtilityActions {

  static func clearWatchLater() throws {
    try FileManager.default.removeItem(atPath: Utility.watchLaterURL.path)
    Utility.createDirIfNotExist(url: Utility.watchLaterURL)
  }

  static func clearPlaybackHistory() {
    HistoryController.shared.removeAll()
    AppDelegate.shared.clearRecentDocuments(nil)
    Preference.set(nil, for: .iinaLastPlayedFilePath)
  }

  static func clearThumbnailCache() {
    ThumbnailCache.clearThumbnailCache()
  }

  struct DefaultApplicationResult {
    let succeeded: Int
    let failed: Int
  }

  /// Registers UniPlayer as the default handler for the selected media types.
  /// Returns `nil` when the bundle has no usable type declarations.
  static func setAsDefaultApplication(
    video: Bool,
    audio: Bool,
    playlists: Bool
  ) -> DefaultApplicationResult? {
    guard
      let utiImportedTypes = Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]],
      let cfBundleID = Bundle.main.bundleIdentifier as CFString?
    else { return nil }

    Logger.log("Setting this app as default")

    let utiChecked = [
      "public.movie": video,
      "public.audio": audio,
      "public.text": playlists,
    ]

    var utiTargetSet: Set<String> = []
    for utiImportedType in utiImportedTypes {
      guard
        let identifier = utiImportedType["UTTypeIdentifier"] as? String,
        let conformsTo = utiImportedType["UTTypeConformsTo"] as? [String],
        let tagSpec = utiImportedType["UTTypeTagSpecification"] as? [String: Any],
        let exts = tagSpec["public.filename-extension"] as? [String]
      else { return nil }

      // Make sure that `conformsTo` contains a checked UTI type.
      guard utiChecked.contains(where: { uti, checked in checked && conformsTo.contains(uti) }) else {
        continue
      }

      Logger.log("UTImportedType: \(identifier.quoted) ➤ \(exts)", level: .verbose)
      for ext in exts {
        let uttypesForExt = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
        for uttype in uttypesForExt {
          utiTargetSet.insert(uttype.identifier)
        }
      }
    }

    var succeeded = 0
    var failed = 0
    for identifier in utiTargetSet {
      Logger.log("Setting default for UTI: \(identifier.quoted)", level: .verbose)
      let status = LSSetDefaultRoleHandlerForContentType(identifier as CFString, .all, cfBundleID)
      if status == kOSReturnSuccess {
        succeeded += 1
      } else {
        Logger.log("Failed for \(identifier.quoted): return value \(status)", level: .error)
        failed += 1
      }
    }
    return DefaultApplicationResult(succeeded: succeeded, failed: failed)
  }
}
