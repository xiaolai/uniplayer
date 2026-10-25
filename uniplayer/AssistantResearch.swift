//
//  AssistantResearch.swift
//  uniplayer
//
//  Reviews and discussion come from a deliberate, app-initiated search rather
//  than from a model's memory. The client talks to DeepSeek Search with the
//  assistant key, keeps the result bounded, and never persists a search.
//

import Foundation

struct AssistantResearchSource: Identifiable, Equatable {
  let title: String
  let url: URL
  let siteName: String?
  let date: String?
  let snippet: String
  let summary: String
  let authority: Int
  let rerankScore: Double

  var id: String { url.absoluteString }
  var host: String { url.host ?? "" }
}

struct AssistantResearchResult: Equatable {
  static let maxContextCharacters = 8_000

  let query: String
  let sources: [AssistantResearchSource]

  var isEmpty: Bool { sources.isEmpty }
  var sourceCount: Int { sources.count }

  /// What the model reads. Source URLs are kept beside each summary so an
  /// answer can cite them instead of treating the text as its own memory.
  var formattedForModel: String {
    let header = "Web search results for \"\(query)\":"
    guard !sources.isEmpty else {
      return "Web search returned no results for \"\(query)\"."
    }

    let separator = "\n\n"
    var blocks: [String] = []
    var used = header.count
    for (index, source) in sources.enumerated() {
      var metadata = [source.siteName ?? source.host]
      if let date = source.date, !date.isEmpty { metadata.append(date) }
      if source.authority >= 0 { metadata.append("authority \(source.authority)") }
      let summary = source.summary.isEmpty ? source.snippet : source.summary
      let block = """
      [\(index + 1)] \(source.title)
      URL: \(source.url.absoluteString)
      \(metadata.joined(separator: " · "))
      \(summary)
      """
      let addition = separator.count + block.count
      guard used + addition <= Self.maxContextCharacters else { break }
      blocks.append(block)
      used += addition
    }

    if blocks.isEmpty, let first = sources.first {
      let summary = first.summary.isEmpty ? first.snippet : first.summary
      let block = "[1] \(first.title)\nURL: \(first.url.absoluteString)\n\(summary)"
      return String((header + separator + block).prefix(Self.maxContextCharacters))
    }
    return header + separator + blocks.joined(separator: separator)
  }
}

enum AssistantResearchError: LocalizedError, Equatable {
  case notConfigured
  case unauthorized
  case rateLimited
  case insufficientBalance
  case badRequest
  case unavailable
  case httpStatus(Int)
  case malformedResponse
  case cancelled
  case offline
  case timedOut
  case redirectRefused
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return NSLocalizedString(
        "Web research needs a DeepSeek assistant endpoint and API key.",
        comment: "Research error")
    case .unauthorized:
      return NSLocalizedString("DeepSeek rejected the API key.", comment: "Research error")
    case .rateLimited:
      return NSLocalizedString("DeepSeek Search is rate limited. Try again shortly.", comment: "Research error")
    case .insufficientBalance:
      return NSLocalizedString("The DeepSeek account has insufficient balance.", comment: "Research error")
    case .badRequest:
      return NSLocalizedString("DeepSeek could not understand the search query.", comment: "Research error")
    case .unavailable:
      return NSLocalizedString("DeepSeek Search is unavailable right now.", comment: "Research error")
    case .httpStatus(let code):
      return String(format: NSLocalizedString("DeepSeek Search returned HTTP %d.", comment: "Research error"), code)
    case .malformedResponse:
      return NSLocalizedString("DeepSeek Search returned a response this app could not read.", comment: "Research error")
    case .cancelled:
      return NSLocalizedString("The web search was cancelled.", comment: "Research error")
    case .offline:
      return NSLocalizedString("Could not reach DeepSeek Search.", comment: "Research error")
    case .timedOut:
      return NSLocalizedString("DeepSeek Search took too long to respond.", comment: "Research error")
    case .redirectRefused:
      return NSLocalizedString(
        "DeepSeek Search redirected to a different host. Update the endpoint in Settings.",
        comment: "Research error")
    case .provider(let message):
      return message
    }
  }
}

protocol AssistantResearchProviding {
  func search(query: String, count: Int) async throws -> AssistantResearchResult
}

/// Builds the review query before the request. The site operators make the
/// result set about reception and discussion instead of generic SEO pages.
enum AssistantResearchPlanner {
  static let maxQueryLength = 128

  /// The API counts Unicode scalars. Swift's `prefix` counts grapheme
  /// clusters, so a combining sequence could pass this limit and still be
  /// rejected by the service.
  static func clip(_ text: String, toScalarCount limit: Int) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count > limit else { return text }
    var result = ""
    for scalar in scalars.prefix(limit) {
      result.unicodeScalars.append(scalar)
    }
    return result
  }

  static func reviewsQuery(title: String, metadata: LibraryMetadata?,
                           continuation: Bool) -> String {
    var tail = ""
    if let year = metadata?.year { tail += " \(year)" }
    if let episode = metadata?.episodeCode { tail += " \(episode)" }

    let suffix = continuation
      ? " worth watching reviews discussion "
      : " reviews discussion "
    let sites = "site:reddit.com OR site:letterboxd.com OR site:douban.com"
    // The title is the only part that may be clipped. Year and episode stay
    // in the query even for a very long title because they disambiguate the
    // result more than another word of the title would.
    let budget = max(1, maxQueryLength
      - suffix.unicodeScalars.count
      - sites.unicodeScalars.count
      - tail.unicodeScalars.count)
    let titleText = clip(title, toScalarCount: budget)
    return titleText + tail + suffix + sites
  }
}

/// The standalone DeepSeek Search endpoint. It shares the DeepSeek key with
/// chat but is a separate HTTP API, so it does not use the assistant provider
/// transport.
final class DeepSeekSearchClient: AssistantResearchProviding {
  private let configuration: AssistantConfiguration
  private let session: URLSession

  init(configuration: AssistantConfiguration, session: URLSession = .shared) {
    self.configuration = configuration
    self.session = session
  }

  func search(query: String, count: Int = 6) async throws -> AssistantResearchResult {
    let cleaned = AssistantResearchPlanner.clip(
      query.trimmingCharacters(in: .whitespacesAndNewlines),
      toScalarCount: AssistantResearchPlanner.maxQueryLength)
    guard !cleaned.isEmpty else { throw AssistantResearchError.badRequest }
    guard let url = configuration.deepSeekSearchURL,
          let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else {
      throw AssistantResearchError.notConfigured
    }
    guard let origin = AssistantOrigin(url) else {
      throw AssistantResearchError.notConfigured
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": cleaned,
      "count": min(max(count, 1), 50),
      "need_content": false,
    ])

    let redirectGuard = AssistantRedirectGuard(origin: origin)
    do {
      let (data, response) = try await session.data(
        for: request, delegate: redirectGuard)
      guard !redirectGuard.refused, origin.contains(response.url) else {
        throw AssistantResearchError.redirectRefused
      }
      try Self.validate(response)
      return try Self.decode(data, query: cleaned)
    } catch let error as AssistantResearchError {
      throw error
    } catch {
      if redirectGuard.refused {
        throw AssistantResearchError.redirectRefused
      }
      throw Self.map(error)
    }
  }

  private static func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw AssistantResearchError.malformedResponse
    }
    switch http.statusCode {
    case 200..<300:
      return
    case 401, 403:
      throw AssistantResearchError.unauthorized
    case 402:
      throw AssistantResearchError.insufficientBalance
    case 429:
      throw AssistantResearchError.rateLimited
    case 400:
      throw AssistantResearchError.badRequest
    case 408, 500...599:
      throw AssistantResearchError.unavailable
    default:
      throw AssistantResearchError.httpStatus(http.statusCode)
    }
  }

  private static func decode(_ data: Data,
                             query: String) throws -> AssistantResearchResult {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawResults = object["results"] as? [[String: Any]] else {
      throw AssistantResearchError.malformedResponse
    }
    let sources = rawResults.compactMap(source)
    return AssistantResearchResult(query: query, sources: sources)
  }

  private static func source(_ raw: [String: Any]) -> AssistantResearchSource? {
    guard let urlString = raw["url"] as? String,
          let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          let host = url.host else { return nil }

    let rawTitle = (raw["title"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle?.isEmpty == false ? rawTitle! : host
    let rerank = (raw["rerank_score"] as? NSNumber)?.doubleValue ?? 0
    return AssistantResearchSource(
      title: title,
      url: url,
      siteName: raw["site_name"] as? String,
      date: raw["date"] as? String,
      snippet: raw["snippet"] as? String ?? "",
      summary: raw["summary"] as? String ?? "",
      authority: (raw["authority"] as? NSNumber)?.intValue ?? -1,
      rerankScore: rerank)
  }

  private static func map(_ error: Error) -> AssistantResearchError {
    if let error = error as? AssistantResearchError { return error }
    if error is CancellationError { return .cancelled }
    let nsError = error as NSError
    switch nsError.code {
    case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
         NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
      return .offline
    case NSURLErrorTimedOut:
      return .timedOut
    case NSURLErrorCancelled:
      return .cancelled
    default:
      return .provider(nsError.localizedDescription)
    }
  }
}
