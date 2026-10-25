//
//  AssistantProfiles.swift
//  uniplayer
//
//  The OpenAI-compatible endpoint as a SaySo profile: a service row decides
//  the base address, auth header and token field, and the model list comes
//  from the service rather than from a free-text guess.
//

import Foundation
import SaySoAI

enum AssistantProfiles {
  static let customID = AIProviderProfile.custom.id

  static var known: [AIProviderProfile] {
    AIProviderProfile.known
  }

  static func profile(id: String) -> AIProviderProfile {
    AIProviderProfile.profile(id: id) ?? .custom
  }

  /// The base URL without the `chat/completions` suffix. Existing settings
  /// stored the full endpoint; both forms resolve to the same request.
  static func baseURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
    guard components.scheme == "https" || components.scheme == "http" else { return nil }
    let suffix = "/chat/completions"
    while components.path.hasSuffix("/") && components.path.count > 1 {
      components.path.removeLast()
    }
    if components.path.hasSuffix(suffix) {
      components.path.removeLast(suffix.count)
    }
    while components.path.hasSuffix("/") && components.path.count > 1 {
      components.path.removeLast()
    }
    return components.url
  }

  /// The profile whose documented base address matches an old endpoint.
  static func derivedID(for endpoint: String) -> String {
    guard let base = baseURL(endpoint) else { return customID }
    let target = normalized(base.absoluteString)
    for profile in known where profile.id != customID {
      guard let documented = profile.baseURL else { continue }
      if normalized(documented.absoluteString) == target { return profile.id }
    }
    return customID
  }

  private static func normalized(_ value: String) -> String {
    var text = value.lowercased()
    while text.hasSuffix("/") { text.removeLast() }
    return text
  }

  static func catalogMessage(_ error: Error) -> String {
    guard let error = error as? ModelCatalogError else {
      return error.localizedDescription
    }
    switch error {
    case .noList:
      return NSLocalizedString("This service does not publish a model list.",
                               comment: "Assistant model list")
    case .missingKey:
      return NSLocalizedString("Save the API key before loading models.",
                               comment: "Assistant model list")
    case .unreachable:
      return NSLocalizedString("Could not reach the service to load models.",
                               comment: "Assistant model list")
    case .unauthorised:
      return NSLocalizedString("The service rejected the API key.",
                               comment: "Assistant model list")
    case .rateLimited:
      return NSLocalizedString("The service is rate limited. Try again later.",
                               comment: "Assistant model list")
    case .timeout:
      return NSLocalizedString("The model list request timed out.",
                               comment: "Assistant model list")
    case .cancelled:
      return NSLocalizedString("The model list request was cancelled.",
                               comment: "Assistant model list")
    case .server(_, let message):
      return message
    case .badShape:
      return NSLocalizedString("The service returned a model list this app could not read.",
                               comment: "Assistant model list")
    }
  }
}
