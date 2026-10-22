//
//  ThumbnailCache.swift
//  uniplayer
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let subsystem = Logger.makeSubsystem("thumbcache", ["photo.stack"])

class ThumbnailCache {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  private static let version: CacheVersion = 2
  
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size

  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [
    .compressionFactor: 0.75
  ]
  
  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  static func fileExists(forName name: String) -> Bool {
    return FileManager.default.fileExists(atPath: urlFor(name).path)
  }

  static func fileIsCached(forName name: String, forVideo videoPath: URL?) -> Bool {
    guard let videoPath,
          let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath.path) else {
      log("Cannot get video file attributes", level: .error)
      return false
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      log("Cannot get video file size", level: .error)
      return false
    }

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      log("Cannot get video file modification date", level: .error)
      return false
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)

    // Check metadate in the cache
    if self.fileExists(forName: name) {
      guard let file = try? FileHandle(forReadingFrom: urlFor(name)) else {
        log("Cannot open cache file.", level: .error)
        return false
      }

      let cacheVersion = file.read(type: CacheVersion.self)
      if cacheVersion != version { return false }

      return file.read(type: FileSize.self) == fileSize &&
        file.read(type: FileTimestamp.self) == fileTimestamp
    }

    return false
  }

  /// Write thumbnail cache to file.
  /// This method is expected to be called when the file doesn't exist.
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo videoPath: URL?) {
    log("Writing thumbnail cache...")

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    guard maxCacheSize > 0 else { return }
    if CacheManager.shared.getCacheSize() > maxCacheSize {
      CacheManager.shared.clearOldCache()
    }

    guard let videoPath else {
      log("Cannot write thumbnail cache without a video path.", level: .error)
      return
    }
    guard let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath.path) else {
      log("Cannot get video file attributes", level: .error)
      return
    }
    guard let fileSize = fileAttr[.size] as? FileSize,
          let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      log("Cannot get video file metadata", level: .error)
      return
    }

    // Build the complete payload before touching the destination, then write
    // atomically. A failure cannot leave a partially written cache file.
    var data = Data()
    data.append(Data(bytesOf: version))
    data.append(Data(bytesOf: fileSize))
    data.append(Data(bytesOf: FileTimestamp(fileModifiedDate.timeIntervalSince1970)))

    for tb in thumbnails {
      guard let tiffData = tb.image?.tiffRepresentation,
            let jpegData = NSBitmapImageRep(data: tiffData)?.representation(using: .jpeg, properties: imageProperties) else {
        log("Cannot generate jpeg data.", level: .error)
        return
      }
      let timestampData = Data(bytesOf: tb.realTime)
      let blockLength = Int64(timestampData.count + jpegData.count)
      data.append(Data(bytesOf: blockLength))
      data.append(timestampData)
      data.append(jpegData)
    }

    do {
      try data.write(to: urlFor(name), options: .atomic)
    } catch {
      log("Cannot write thumbnail cache: \(error.localizedDescription)", level: .error)
      return
    }

    CacheManager.shared.needsRefresh = true
    log("Finished writing thumbnail cache.")
  }

  /// Read thumbnail cache to file.
  /// This method is expected to be called when the file exists.
  static func read(forName name: String) -> [FFThumbnail]? {
    log("Reading thumbnail cache...")

    let pathURL = urlFor(name)
    guard let file = try? FileHandle(forReadingFrom: pathURL) else {
      log("Cannot open file.", level: .error)
      return nil
    }
    defer { try? file.close() }
    log("Reading from \(pathURL.path)")

    func invalid(_ message: String) -> [FFThumbnail]? {
      log(message, level: .warning)
      try? file.close()
      deleteCacheFile(at: pathURL)
      return nil
    }

    file.seekToEndOfFile()
    let eof = file.offsetInFile
    guard eof >= UInt64(sizeofMetadata) else {
      return invalid("Cache metadata is truncated. Cache file will be deleted.")
    }
    file.seek(toFileOffset: UInt64(sizeofMetadata))

    var result: [FFThumbnail] = []
    let headerSize = MemoryLayout<Int64>.size + MemoryLayout<Double>.size

    while file.offsetInFile < eof {
      let remainingBefore = eof - file.offsetInFile
      guard remainingBefore >= UInt64(headerSize),
            let blockLength = file.read(type: Int64.self),
            let timestamp = file.read(type: Double.self) else {
        return invalid("Cannot read image header. Cache file will be deleted.")
      }
      guard let jpegLength = validatedJPEGLength(
        blockLength: blockLength,
        remainingBytes: eof - file.offsetInFile) else {
        return invalid("Invalid or truncated image block. Cache file will be deleted.")
      }
      let jpegData = file.readData(ofLength: jpegLength)
      guard jpegData.count == jpegLength, let image = NSImage(data: jpegData) else {
        return invalid("Cannot read image. Cache file will be deleted.")
      }
      let tb = FFThumbnail()
      tb.realTime = timestamp
      tb.image = image
      result.append(tb)
    }

    log("Finished reading thumbnail cache, \(result.count) in total")
    return result
  }

  /// Validates a cache block length against the bytes left in the file.
  ///
  /// Returns the JPEG payload length, or `nil` when the record is negative,
  /// absurdly large, or longer than the remaining file.
  static func validatedJPEGLength(blockLength: Int64, remainingBytes: UInt64) -> Int? {
    let timestampSize = MemoryLayout<Double>.size
    guard blockLength >= Int64(timestampSize),
          blockLength <= Int64(64 * 1024 * 1024) else { return nil }
    let jpegLength = Int(blockLength) - timestampSize
    guard jpegLength >= 0, UInt64(jpegLength) <= remainingBytes else { return nil }
    return jpegLength
  }

  static func clearThumbnailCache() {
    try? FileManager.default.removeItem(atPath: Utility.thumbnailCacheURL.path)
    Utility.createDirIfNotExist(url: Utility.thumbnailCacheURL)
  }

  private static func deleteCacheFile(at pathURL: URL) {
    // try deleting corrupted cache
    do {
      try FileManager.default.removeItem(at: pathURL)
    } catch {
      log("Cannot delete corrupted cache.", level: .error)
    }
  }

  private static func urlFor(_ name: String) -> URL {
    return Utility.thumbnailCacheURL.appendingPathComponent(name)
  }

}
