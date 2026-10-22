//
//  KeychainAccess.swift
//  uniplayer
//
//  Created by Collider LI on 25/8/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Foundation

class KeychainAccess {

  enum KeychainError: Error {
    case noResult
    case unhandledError(message: String)
    case unexpectedData
  }

  struct ServiceName: RawRepresentable {
    typealias RawValue = String
    var rawValue: String

    init(rawValue: String) {
      self.rawValue = rawValue
    }

    init(_ rawValue: String) {
      self.init(rawValue: rawValue)
    }

    static let openSubAccount = ServiceName(rawValue: "UniPlayer OpenSubtitles Account")
    static let httpAuth = ServiceName(rawValue: "UniPlayer Saved HTTP Password")
    static let assistantAPIKey = ServiceName(rawValue: "UniPlayer Assistant API Key")
  }

  static func identityQuery(username: String?, service: ServiceName, server: String?, port: Int?) -> [String: Any] {
    var query: [String: Any] = [kSecAttrService as String: service.rawValue]
    if let username { query[kSecAttrAccount as String] = username }
    if let server { query[kSecAttrServer as String] = server }
    if let port { query[kSecAttrPort as String] = port }
    query[kSecClass as String] = server == nil && port == nil ? kSecClassGenericPassword : kSecClassInternetPassword
    return query
  }

  static func write(username: String, password: String, forService serviceName: ServiceName, server: String? = nil, port: Int? = nil) throws {
    guard let passwordData = password.data(using: .utf8) else {
      throw KeychainError.unexpectedData
    }

    let identity = identityQuery(username: username, service: serviceName, server: server, port: port)
    var status: OSStatus

    // Try to replace the value directly. This also overwrites an item whose
    // data cannot be decoded, which the old read-first flow could not do.
    status = SecItemUpdate(
      identity as CFDictionary,
      [kSecValueData as String: passwordData] as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = identity
      addQuery[kSecAttrLabel as String] = serviceName.rawValue
      addQuery[kSecValueData as String] = passwordData
      status = SecItemAdd(addQuery as CFDictionary, nil)
      if status == errSecDuplicateItem {
        // Another writer inserted the item between update and add.
        status = SecItemUpdate(
          identity as CFDictionary,
          [kSecValueData as String: passwordData] as CFDictionary)
      }
    }

    guard status != errSecItemNotFound else { throw KeychainError.noResult }
    guard status == errSecSuccess else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
      throw KeychainError.unhandledError(message: message)
    }
  }

  /// Removes the credential. A missing credential is the requested end state,
  /// not an error.
  static func remove(username: String?, forService serviceName: ServiceName,
                     server: String? = nil, port: Int? = nil) throws {
    let query = identityQuery(username: username, service: serviceName, server: server, port: port)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
      throw KeychainError.unhandledError(message: message)
    }
  }

  static func read(username: String?, forService serviceName: ServiceName, server: String? = nil, port: Int? = nil) throws -> (username: String, password: String) {
    var query = identityQuery(username: username, service: serviceName, server: server, port: port)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = true

    // initiate the search
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else { throw KeychainError.noResult }
    guard status == errSecSuccess else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
      throw KeychainError.unhandledError(message: message)
    }

    // get data
    guard let existingItem = item as? [String : Any],
      let passwordData = existingItem[kSecValueData as String] as? Data,
      let password = String(data: passwordData, encoding: String.Encoding.utf8),
      let account = existingItem[kSecAttrAccount as String] as? String
      else {
        throw KeychainError.unexpectedData
    }
    return (account, password)
  }

}

