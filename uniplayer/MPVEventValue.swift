//
//  MPVEventValue.swift
//  uniplayer
//
//  Copies values out of mpv-owned event memory into Swift values.
//

import Foundation

enum MPVEventValue {

  enum Format {
    case flag
    case int64
    case double
    case string
    case node
  }

  /// Decodes and copies a property value.
  ///
  /// mpv documents that the data referenced by `mpv_event_property` is only
  /// valid until the next call to `mpv_wait_event`. Callers must invoke this
  /// while the event queue is still blocked, before dispatching the result.
  static func copy(format: Format, data: UnsafeMutableRawPointer?, name: String) -> Any? {
    guard let data else { return nil }
    switch format {
    case .flag:
      // MPV_FORMAT_FLAG is a C int, not a Swift Bool.
      return data.assumingMemoryBound(to: Int32.self).pointee != 0
    case .int64:
      return data.assumingMemoryBound(to: Int64.self).pointee
    case .double:
      return data.assumingMemoryBound(to: Double.self).pointee
    case .string:
      guard let string = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else {
        return nil
      }
      return String(cString: string)
    case .node:
      do {
        return try MPVNode.parse(data.assumingMemoryBound(to: mpv_node.self).pointee) ?? NSNull()
      } catch {
        Logger.log("Cannot parse mpv node for \(name): \(error)", level: .error)
        return nil
      }
    }
  }
}
