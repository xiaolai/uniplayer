//
//  MPVOptionsStore.swift
//  uniplayer
//
//  Persistence for additional mpv options, shared by both settings interfaces.
//

import Foundation

enum MPVOptionsStore {

  enum Column {
    case key
    case value
  }

  /// Loads the saved options, or `nil` when the stored value has the wrong shape.
  static func load() -> [[String]]? {
    guard let options = Preference.value(for: .userOptions) as? [[String]] else {
      return nil
    }
    return options
  }

  static func save(_ options: [[String]]) {
    Preference.set(options, for: .userOptions)
    UserDefaults.standard.synchronize()
  }

  /// Appends a new blank option and returns its row.
  @discardableResult
  static func append(_ options: inout [[String]]) -> Int {
    options.append(["name", "value"])
    return options.count - 1
  }

  static func remove(at row: Int, from options: inout [[String]]) -> Bool {
    guard options.indices.contains(row) else { return false }
    options.remove(at: row)
    return true
  }

  /// Updates one cell. Returns `false` when the value is empty or the row is gone.
  static func set(_ value: String, row: Int, column: Column, in options: inout [[String]]) -> Bool {
    guard !value.isEmpty, options.indices.contains(row) else { return false }
    switch column {
    case .key: options[row][0] = value
    case .value: options[row][1] = value
    }
    return true
  }
}
