// Netflix-only card enhancement. Credentials never enter the webpage.
import AppKit
import WebKit

struct NetflixRating: Codable, Equatable {
  let imdbID: String
  let score: Double
  let votes: Int
  let verified: Bool?
  var year: String?
  var type: String?
  var matchedTitle: String?
  var userConfirmed: Bool?

  init(imdbID: String, score: Double, votes: Int, verified: Bool = false, year: String? = nil, type: String? = nil, matchedTitle: String? = nil, userConfirmed: Bool = false) {
    self.imdbID = imdbID; self.score = score; self.votes = votes; self.verified = verified
    self.year = year; self.type = type; self.matchedTitle = matchedTitle; self.userConfirmed = userConfirmed
  }

  var badge: String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), score) + " (\(Self.voteCount(votes)))" }

  static func voteCount(_ count: Int) -> String {
    let units: [(Double, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
    for (divisor, suffix) in units where Double(count) >= divisor {
      let value = (Double(count) / divisor * 10).rounded() / 10
      if value >= 1000, let next = units.first(where: { $0.0 == divisor * 1000 }) {
        return "1" + next.1
      }
      return (value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)) + suffix
    }
    return String(count)
  }
}

struct NetflixRatingQuery: Codable, Hashable {
  let netflixID: String
  let title: String
  let year: String?
  let type: String?
  let episode: Bool

  var cacheKey: String { netflixID.isEmpty ? "title:\(Self.normalized(title)):\(year ?? ""):\(type ?? "")" : netflixID }

  init?(body: Any) {
    guard let body = body as? [String: Any], let rawTitle = body["title"] as? String else { return nil }
    let id = body["id"] as? String ?? ""
    guard id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 300 else { return nil }
    netflixID = id
    self.title = title
    let rawYear = body["year"] as? String ?? ""
    year = rawYear.count == 4 && (1870...2100).contains(Int(rawYear) ?? 0) ? rawYear : nil
    let rawType = body["type"] as? String ?? ""
    type = ["movie", "series"].contains(rawType) ? rawType : nil
    episode = body["episode"] as? Bool ?? false
  }

  private enum CodingKeys: String, CodingKey { case netflixID, title, year, type, episode }
  init(from decoder: Decoder) throws {
    let data = try decoder.container(keyedBy: CodingKeys.self)
    netflixID = try data.decode(String.self, forKey: .netflixID)
    title = try data.decode(String.self, forKey: .title)
    year = try data.decodeIfPresent(String.self, forKey: .year)
    type = try data.decodeIfPresent(String.self, forKey: .type)
    episode = try data.decodeIfPresent(Bool.self, forKey: .episode) ?? false
  }

  static func normalized(_ title: String) -> String {
    title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined()
  }
}

/// Public Netflix title pages expose the original year and format in a
/// semantic metadata list. No signed-in cookies or private page state are read.
struct NetflixTitleMetadata: Equatable {
  let year: String
  let type: String

  static func parse(_ html: String) -> NetflixTitleMetadata? {
    guard let body = html.range(of: "<body", options: .caseInsensitive) else { return nil }
    let html = String(html[body.lowerBound...])
    guard let lists = try? NSRegularExpression(pattern: "<ul\\b[^>]*>(.*?)</ul>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
          let items = try? NSRegularExpression(pattern: "<li\\b[^>]*>(.*?)</li>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
    for list in lists.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(list.range(at: 1), in: html) else { continue }
      let content = String(html[range])
      let values = items.matches(in: content, range: NSRange(content.startIndex..., in: content)).prefix(2).compactMap { match -> String? in
        guard let range = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[range]).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
          .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard values.count == 2, values[0].count == 4, let year = Int(values[0]), (1870...2100).contains(year) else { continue }
      let format = values[1].lowercased()
      if format.range(of: #"\b(series|seasons?|parts?|episodes?)\b"#, options: .regularExpression) != nil {
        return NetflixTitleMetadata(year: values[0], type: "series")
      }
      let duration = format.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
      if duration.range(of: #"^(\d+h(\d+m)?|\d+m)$"#, options: .regularExpression) != nil {
        return NetflixTitleMetadata(year: values[0], type: "movie")
      }
    }
    return nil
  }
}

/// Explicit outcomes keep a deferred/network failure distinct from an absent title.
struct NetflixRatingResult {
  let rating: NetflixRating?
  let state: String
  let reason: String
  let retryAfter: TimeInterval
  let stale: Bool
  static func ready(_ rating: NetflixRating, stale: Bool = false, retryAfter: TimeInterval = 0) -> Self {
    Self(rating: rating, state: "ready", reason: "", retryAfter: retryAfter, stale: stale)
  }
  static func miss(_ reason: String = "notFound") -> Self {
    Self(rating: nil, state: "notFound", reason: reason, retryAfter: 300, stale: false)
  }
  static func retry(_ reason: String, _ after: TimeInterval) -> Self {
    Self(rating: nil, state: "retry", reason: reason, retryAfter: max(1, after), stale: false)
  }
  var payload: [String: Any] {
    var result: [String: Any] = ["state": state, "reason": reason, "retryAfter": retryAfter, "stale": stale]
    if let rating {
      result.merge(["badge": rating.badge, "imdbID": rating.imdbID, "score": rating.score,
                    "votes": rating.votes, "verified": rating.verified == true,
                    "matchedTitle": rating.matchedTitle ?? "", "matchedYear": rating.year ?? "",
                    "matchedType": rating.type ?? "", "userConfirmed": rating.userConfirmed == true]) { $1 }
    }
    return result
  }
}

@MainActor
final class NetflixRatingService {
  static let shared = NetflixRatingService()
  static let enabledKey = "netflix.imdbRatings.enabled.v1"
  static let changed = Notification.Name("NetflixRatingsConfigurationChanged")
  static let statusChanged = Notification.Name("NetflixRatingsStatusChanged")
  static let keychainService = KeychainAccess.ServiceName("UniPlayer OMDb API Key")
  static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

  private(set) var status = ""
  private let session: URLSession
  private let cacheURL: URL?
  private let overrideURL: URL?
  private let identityURL: URL?
  private let credential: () -> String?
  private let now: () -> Date
  private struct Entry: Codable { let query: NetflixRatingQuery; let rating: NetflixRating?; let expires: Date; let resolverVersion: Int? }
  private struct Show: Codable { let id: String; let title: String }
  private var cache: [String: Entry] = [:]
  private var overrides: [String: String] = [:]
  private var shows: [String: Show] = [:]
  private var pending: [NetflixRatingQuery: Task<NetflixRatingResult, Never>] = [:]
  private var active = 0
  private var order = 0
  private struct Waiter { let priority: Int; let order: Int; let continuation: CheckedContinuation<Bool, Never> }
  private var waiters: [Waiter] = []
  private var suspendedUntil = Date.distantPast
  private var suspensionReason = "network"
  private var budgetStart = Date.distantPast
  private var budgetCount = 0
  private var generation = 0

  init(session: URLSession = URLSession(configuration: .ephemeral),
       cacheURL: URL? = Utility.appSupportDirUrl.appendingPathComponent("netflix-ratings-v1.json"),
       overrideURL: URL? = Utility.appSupportDirUrl.appendingPathComponent("netflix-imdb-overrides-v1.json"),
       identityURL: URL? = Utility.appSupportDirUrl.appendingPathComponent("netflix-show-identities-v1.json"),
       now: @escaping () -> Date = Date.init,
       credential: @escaping () -> String? = {
         (try? KeychainAccess.read(username: NSUserName(), forService: keychainService))?.password
       }) {
    self.session = session; self.cacheURL = cacheURL; self.overrideURL = overrideURL
    self.identityURL = identityURL; self.now = now; self.credential = credential
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
       let entries = try? JSONDecoder().decode([String: Entry].self, from: data) { cache = entries }
    if let overrideURL, let data = try? Data(contentsOf: overrideURL),
       let saved = try? JSONDecoder().decode([String: String].self, from: data) { overrides = saved.filter { Self.validIMDbID($0.value) } }
    if let identityURL, let data = try? Data(contentsOf: identityURL),
       let saved = try? JSONDecoder().decode([String: Show].self, from: data) { shows = saved }
  }

  func configurationChanged(clearProviderPause: Bool = true) {
    generation += 1
    pending.values.forEach { $0.cancel() }; pending.removeAll()
    let cancelled = waiters; waiters.removeAll(); cancelled.forEach { $0.continuation.resume(returning: false) }
    if clearProviderPause {
      suspendedUntil = .distantPast; budgetStart = .distantPast; budgetCount = 0; setStatus("")
    }
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

  private func setStatus(_ text: String) {
    status = text
    NotificationCenter.default.post(name: Self.statusChanged, object: nil)
  }

  static func validIMDbID(_ id: String) -> Bool {
    id.hasPrefix("tt") && (7...12).contains(id.dropFirst(2).count)
      && id.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
  }

  static func parsedIMDbID(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if validIMDbID(value) { return value }
    guard let url = URL(string: value), url.scheme == "https",
          let host = url.host?.lowercased(), host == "imdb.com" || host.hasSuffix(".imdb.com") else { return nil }
    let parts = url.path.split(separator: "/")
    guard parts.count >= 2, parts[0] == "title", validIMDbID(String(parts[1])) else { return nil }
    return String(parts[1])
  }

  func override(for id: String) -> String? { overrides[id] }

  func saveOverride(_ imdbID: String?, for id: String) throws {
    guard !id.isEmpty, id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }),
          imdbID == nil || Self.validIMDbID(imdbID!) else { throw URLError(.badURL) }
    var saved = overrides; saved[id] = imdbID
    if let overrideURL { try write(saved, to: overrideURL) }
    overrides = saved
    if let imdbID, let entry = cache[id], let rating = entry.rating, rating.imdbID == imdbID {
      let confirmed = NetflixRating(imdbID: rating.imdbID, score: rating.score, votes: rating.votes,
        verified: true, year: rating.year, type: rating.type, matchedTitle: rating.matchedTitle, userConfirmed: true)
      remember(entry.query, rating: confirmed, until: entry.expires)
    } else { cache[id] = nil; if let cacheURL { try? write(cache, to: cacheURL) } }
    configurationChanged(clearProviderPause: false)
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
  }

  func lookup(_ query: NetflixRatingQuery) async -> NetflixRating? { await outcome(query).rating }

  func outcome(_ query: NetflixRatingQuery, priority: Int = 0, force: Bool = false) async -> NetflixRatingResult {
    let entry = cache[query.cacheKey]
    let savedID = overrides[query.netflixID]
    var stored: NetflixRating?
    if let entry, let rating = entry.rating,
       (savedID != nil ? savedID == rating.imdbID : NetflixRatingQuery.normalized(entry.query.title) == NetflixRatingQuery.normalized(query.title)),
       savedID != nil || ((query.year == nil || query.year == rating.year) && (query.type == nil || query.type == rating.type)) {
      let confirmed = savedID != nil || (entry.resolverVersion == 3 && rating.verified == true)
      stored = NetflixRating(imdbID: rating.imdbID, score: rating.score, votes: rating.votes,
        verified: confirmed, year: rating.year, type: rating.type, matchedTitle: rating.matchedTitle, userConfirmed: savedID != nil)
      let strongerHints = query.year != nil && query.type != nil && query != entry.query && stored?.verified != true
      if entry.expires > now(), entry.resolverVersion == 3, !force, !strongerHints {
        if stored != rating { remember(query, rating: stored, until: entry.expires) }
        return .ready(stored!)
      }
    }
    if let entry, entry.rating == nil, entry.query == query, entry.expires > now(), entry.resolverVersion == 3, !force { return .miss() }
    if now() < suspendedUntil {
      let delay = suspendedUntil.timeIntervalSince(now())
      return stored.map { .ready($0, stale: true, retryAfter: delay) } ?? .retry(suspensionReason, delay)
    }
    guard let key = credential(), !key.isEmpty else {
      setStatus("Add your OMDb API key to show Netflix ratings.")
      return stored.map { .ready($0, stale: true, retryAfter: 60) } ?? .retry("credentials", 60)
    }
    guard pending[query] != nil || pending.count < 100 else { return stored.map { .ready($0, stale: true, retryAfter: 2) } ?? .retry("deferred", 2) }
    let task = taskFor(query, priority: priority, key: key)
    if let stored, !force { return .ready(stored, stale: true, retryAfter: 2) }
    return await task.value
  }

  private func taskFor(_ query: NetflixRatingQuery, priority: Int, key: String) -> Task<NetflixRatingResult, Never> {
    if let task = pending[query] { return task }
    let expected = generation
    let task = Task { @MainActor in
      guard await acquire(priority) else { return NetflixRatingResult.retry("cancelled", 1) }
      defer { release() }
      guard !Task.isCancelled else {
        if self.generation == expected { self.pending[query] = nil }
        return NetflixRatingResult.retry("cancelled", 1)
      }
      let result = await resolve(query, key: key, expected: expected)
      if generation == expected { pending[query] = nil }
      return result
    }
    pending[query] = task
    return task
  }

  private func acquire(_ priority: Int) async -> Bool {
    if active < 2 { active += 1; return true }
    order += 1
    let position = order
    return await withCheckedContinuation { waiters.append(Waiter(priority: priority, order: position, continuation: $0)) }
  }

  private func release() {
    if waiters.isEmpty { active -= 1; return }
    waiters.sort { $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority }
    waiters.removeFirst().continuation.resume(returning: true)
  }

  private enum Failure: Error { case network, credentials, quota, response, deferred(TimeInterval) }

  private func request(_ params: [String: String], key: String) async throws -> [String: Any] {
    try Task.checkCancellation()
    if now() < suspendedUntil { throw Failure.deferred(suspendedUntil.timeIntervalSince(now())) }
    if now().timeIntervalSince(budgetStart) >= 60 { budgetStart = now(); budgetCount = 0 }
    guard budgetCount < 60 else { throw Failure.deferred(60 - now().timeIntervalSince(budgetStart)) }
    budgetCount += 1
    var components = URLComponents(string: "https://www.omdbapi.com/")!
    components.queryItems = params.merging(["apikey": key]) { $1 }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!); request.timeoutInterval = 12; request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else { throw Failure.network }
    if response.statusCode == 401 { throw Failure.credentials }
    if response.statusCode == 429 { throw Failure.quota }
    guard response.statusCode == 200, data.count < 1_000_000,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.response }
    let error = (json["Error"] as? String ?? "").lowercased()
    if error.contains("api key") { throw Failure.credentials }
    if error.contains("limit") { throw Failure.quota }
    if json["Response"] as? String == "False", !error.contains("not found") { throw Failure.response }
    return json
  }

  private func episodeShow(_ id: String) async throws -> Show {
    if let show = shows[id] { return show }
    var request = URLRequest(url: URL(string: "https://www.netflix.com/title/\(id)")!); request.timeoutInterval = 8
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          let url = response.url, NetflixRatingsBridge.isNetflix(url), data.count < 4_000_000,
          let html = String(data: data, encoding: .utf8),
          let pattern = try? NSRegularExpression(pattern: "<h1[^>]*>(.*?)</h1>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
          let match = pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          let range = Range(match.range(at: 1), in: html) else { throw Failure.network }
    let parts = url.path.split(separator: "/")
    guard let titleIndex = parts.firstIndex(of: "title"), parts.count > titleIndex + 1 else { throw Failure.network }
    let showID = String(parts[titleIndex + 1])
    guard showID != id || NetflixTitleMetadata.parse(html)?.type == "series" else { throw Failure.network }
    var title = String(html[range]).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    for (entity, value) in ["&amp;": "&", "&#x27;": "'", "&#39;": "'", "&quot;": "\"", "&nbsp;": " "] { title = title.replacingOccurrences(of: entity, with: value) }
    guard !title.isEmpty, title.count <= 300 else { throw Failure.response }
    let show = Show(id: showID, title: title); shows[id] = show
    if let identityURL { try? write(shows, to: identityURL) }
    return show
  }

  private func resolve(_ query: NetflixRatingQuery, key: String, expected: Int) async -> NetflixRatingResult {
    do {
      let savedID = overrides[query.netflixID]
      let show = savedID == nil && query.episode && !query.netflixID.isEmpty ? try await episodeShow(query.netflixID) : nil
      let title = show?.title ?? query.title
      let type = show != nil ? "series" : query.type
      let strongHints = savedID == nil && query.year != nil && type != nil
      var detail: [String: Any]
      var uniqueMatch = false
      var cachedCandidate: NetflixRating?
      if let value = cache[query.cacheKey]?.rating,
         NetflixRatingQuery.normalized(value.matchedTitle ?? query.title) == NetflixRatingQuery.normalized(title),
         value.year == query.year, value.type == type { cachedCandidate = value }
      if strongHints {
        var searchParams = ["s": title, "y": query.year!]; searchParams["type"] = type
        let search = try await request(searchParams, key: key)
        let candidates = (search["Search"] as? [[String: Any]] ?? []).filter {
          NetflixRatingQuery.normalized($0["Title"] as? String ?? "") == NetflixRatingQuery.normalized(title)
            && $0["Type"] as? String == type && String(($0["Year"] as? String ?? "").prefix(4)) == query.year
        }
        uniqueMatch = (Int(search["totalResults"] as? String ?? "0") ?? 0) <= 10 && candidates.count == 1
        if uniqueMatch, let id = candidates.first?["imdbID"] as? String, Self.validIMDbID(id) {
          if let cachedCandidate, cachedCandidate.imdbID == id {
            guard generation == expected, !Task.isCancelled else { return .retry("cancelled", 1) }
            let confirmed = NetflixRating(imdbID: id, score: cachedCandidate.score, votes: cachedCandidate.votes,
              verified: true, year: cachedCandidate.year, type: cachedCandidate.type, matchedTitle: cachedCandidate.matchedTitle)
            remember(query, rating: confirmed, until: now().addingTimeInterval(7 * 24 * 3600)); return .ready(confirmed)
          }
          detail = try await request(["i": id], key: key)
        } else {
          if let cachedCandidate {
            guard generation == expected, !Task.isCancelled else { return .retry("cancelled", 1) }
            let tentative = NetflixRating(imdbID: cachedCandidate.imdbID, score: cachedCandidate.score, votes: cachedCandidate.votes,
              verified: false, year: cachedCandidate.year, type: cachedCandidate.type, matchedTitle: cachedCandidate.matchedTitle)
            remember(query, rating: tentative, until: now().addingTimeInterval(300)); return .ready(tentative)
          }
          detail = try await request(["t": title, "y": query.year!, "type": type!], key: key)
        }
      } else {
        var params = savedID.map { ["i": $0] } ?? ["t": title]
        if savedID == nil { if let type { params["type"] = type }; if let year = query.year { params["y"] = year } }
        detail = try await request(params, key: key)
      }
      func matches(_ value: [String: Any]) -> Bool {
        if savedID != nil { return value["imdbID"] as? String == savedID }
        guard NetflixRatingQuery.normalized(value["Title"] as? String ?? "") == NetflixRatingQuery.normalized(title) else { return false }
        if let type, value["Type"] as? String != type { return false }
        if let year = query.year, String((value["Year"] as? String ?? "").prefix(4)) != year { return false }
        return true
      }
      guard generation == expected, !Task.isCancelled else { return .retry("cancelled", 1) }
      guard matches(detail), let id = detail["imdbID"] as? String, Self.validIMDbID(id),
            ["movie", "series"].contains(detail["Type"] as? String ?? ""),
            let score = Double(detail["imdbRating"] as? String ?? ""), score.isFinite, (0...10).contains(score),
            let votes = Int((detail["imdbVotes"] as? String ?? "").replacingOccurrences(of: ",", with: "")), votes > 0 else {
        remember(query, rating: nil, until: now().addingTimeInterval(300)); return .miss()
      }
      let rating = NetflixRating(imdbID: id, score: score, votes: votes,
        verified: savedID != nil || uniqueMatch,
        year: String((detail["Year"] as? String ?? "").prefix(4)), type: detail["Type"] as? String,
        matchedTitle: detail["Title"] as? String, userConfirmed: savedID != nil)
      remember(query, rating: rating, until: now().addingTimeInterval(7 * 24 * 3600))
      setStatus("Ratings are working.")
      return .ready(rating)
    } catch {
      guard generation == expected, !Task.isCancelled else { return .retry("cancelled", 1) }
      let reason: String; let delay: TimeInterval
      switch error {
      case Failure.deferred(let after): return .retry("deferred", after)
      case Failure.credentials: reason = "credentials"; delay = 3600
      case Failure.quota: reason = "quota"; delay = 3600
      default: reason = "network"; delay = 30
      }
      suspendedUntil = now().addingTimeInterval(delay); suspensionReason = reason
      setStatus(reason == "credentials" ? "OMDb rejected the API key. Save a valid key to retry." : reason == "quota" ? "OMDb’s request limit was reached. Cached ratings remain available." : "Couldn’t reach OMDb. Ratings will retry automatically.")
      return .retry(reason, delay)
    }
  }

  private func remember(_ query: NetflixRatingQuery, rating: NetflixRating?, until expiry: Date) {
    cache[query.cacheKey] = Entry(query: query, rating: rating, expires: expiry, resolverVersion: 3)
    if cache.count > 5000 {
      cache = cache.filter { $0.value.expires > now() }
      if cache.count > 5000 { cache = Dictionary(uniqueKeysWithValues: cache.prefix(5000).map { ($0.key, $0.value) }) }
    }
    if let cacheURL { try? write(cache, to: cacheURL) }
  }
}

@MainActor
final class NetflixRatingsBridge: NSObject, WKScriptMessageHandlerWithReply {
  static let world = WKContentWorld.world(name: "UniPlayerNetflixRatings")
  var openIMDb: ((URL) -> Void)?
  enum EditDecision { case save(String), automatic, cancel }
  var presentMatchEditor: ((NetflixRatingQuery, String?, @escaping (EditDecision) -> Void) -> Void)?
  private let service: NetflixRatingService
  private weak var webView: WKWebView?
  private var observer: NSObjectProtocol?
  private var documentGeneration = 0

  init(service: NetflixRatingService = .shared) { self.service = service }

  static func isNetflix(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host == "netflix.com" || host.hasSuffix(".netflix.com")
  }

  static var script: String {
    let source = Bundle.main.url(forResource: "NetflixRatings", withExtension: "js")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    let icons = ["verified": Tokens.NetflixRatings.verifiedIcon, "unverified": Tokens.NetflixRatings.unverifiedIcon, "edit": Tokens.NetflixRatings.editIcon]
    return "globalThis.uniPlayerRatingCSS = \(String(data: try! JSONEncoder().encode(Tokens.NetflixRatings.css), encoding: .utf8)!);\n"
      + "globalThis.uniPlayerRatingIcons = \(String(data: try! JSONEncoder().encode(icons), encoding: .utf8)!);\n" + source
  }

  func install(in configuration: WKWebViewConfiguration) {
    configuration.userContentController.addScriptMessageHandler(self, contentWorld: Self.world, name: "netflixRatings")
    configuration.userContentController.addUserScript(WKUserScript(source: Self.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
  }

  func attach(to webView: WKWebView) {
    self.webView = webView
    observer = NotificationCenter.default.addObserver(forName: NetflixRatingService.changed, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        self?.webView?.evaluateJavaScript("globalThis.uniPlayerRatings?.reset()", in: nil, in: Self.world, completionHandler: nil)
      }
    }
  }

  func navigationStarted() { documentGeneration += 1 }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard message.frameInfo.isMainFrame, Self.isNetflix(message.frameInfo.request.url),
          Self.isNetflix(message.webView?.url), let body = message.body as? [String: Any] else {
      replyHandler(nil, "Unavailable on this page"); return
    }
    guard NetflixRatingService.enabled else { replyHandler(["disabled": true], nil); return }
    if body["action"] as? String == "editMatch", let query = NetflixRatingQuery(body: body), !query.netflixID.isEmpty {
      let current = service.override(for: query.netflixID) ?? (body["imdbID"] as? String).flatMap { NetflixRatingService.validIMDbID($0) ? $0 : nil }
      let finish: (EditDecision) -> Void = { [weak self] decision in
        guard let self else { replyHandler(["changed": false], nil); return }
        do {
          switch decision {
          case .save(let id): try self.service.saveOverride(id, for: query.netflixID)
          case .automatic: try self.service.saveOverride(nil, for: query.netflixID)
          case .cancel: replyHandler(["changed": false], nil); return
          }
          replyHandler(["changed": true], nil)
        } catch { replyHandler(nil, "Could not save IMDb match") }
      }
      if let presentMatchEditor { presentMatchEditor(query, current, finish) }
      else { showMatchEditor(query, current: current, completion: finish) }
      return
    }
    if body["action"] as? String == "search", let title = body["title"] as? String,
       !title.isEmpty, title.count <= 300 {
      var url = URLComponents(string: "https://www.imdb.com/find/")!
      url.queryItems = [URLQueryItem(name: "q", value: title), URLQueryItem(name: "s", value: "tt")]
      if let url = url.url { openIMDb?(url) }
      replyHandler(["ok": true], nil); return
    }
    if body["action"] as? String == "open", let id = body["imdbID"] as? String,
       NetflixRatingService.validIMDbID(id) {
      openIMDb?(URL(string: "https://www.imdb.com/title/\(id)/")!)
      replyHandler(["ok": true], nil); return
    }
    guard let query = NetflixRatingQuery(body: body) else { replyHandler(nil, "Invalid title"); return }
    let expectedDocument = documentGeneration
    let priority = min(50, max(0, body["priority"] as? Int ?? 0))
    Task { @MainActor [weak self] in
      guard let self else { replyHandler([:], nil); return }
      let result = await self.service.outcome(query, priority: priority)
      guard NetflixRatingService.enabled else { replyHandler(["state": "disabled", "disabled": true], nil); return }
      guard self.documentGeneration == expectedDocument else { replyHandler(NetflixRatingResult.retry("navigation", 1).payload, nil); return }
      replyHandler(result.payload, nil)
    }
  }

  private func showMatchEditor(_ query: NetflixRatingQuery, current: String?, completion: @escaping (EditDecision) -> Void) {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Confirm IMDb Match", comment: "Netflix ratings")
    alert.informativeText = query.title + "\n\n" + NSLocalizedString("Paste an IMDb title URL or ID. This correction is saved for this Netflix title.", comment: "Netflix ratings")
    alert.addButton(withTitle: NSLocalizedString("Save Match", comment: "Netflix ratings"))
    alert.addButton(withTitle: NSLocalizedString("Use Automatic Match", comment: "Netflix ratings"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
    let field = NSTextField(frame: NSRect(x: Tokens.Space.n0, y: Tokens.Space.n0, width: Tokens.Size.n260, height: Tokens.Size.n28))
    field.placeholderString = "https://www.imdb.com/title/tt10048342/"
    field.stringValue = current ?? ""
    field.setAccessibilityLabel(NSLocalizedString("IMDb URL or ID", comment: "Netflix ratings"))
    alert.accessoryView = field
    alert.buttons[0].isEnabled = NetflixRatingService.parsedIMDbID(field.stringValue) != nil
    alert.buttons[1].isEnabled = service.override(for: query.netflixID) != nil
    let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
      MainActor.assumeIsolated { alert.buttons[0].isEnabled = NetflixRatingService.parsedIMDbID(field.stringValue) != nil }
    }
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      NotificationCenter.default.removeObserver(observer)
      if response == .alertFirstButtonReturn, let id = NetflixRatingService.parsedIMDbID(field.stringValue) { completion(.save(id)) }
      else if response == .alertSecondButtonReturn { completion(.automatic) }
      else { completion(.cancel) }
    }
    if let window = webView?.window { alert.beginSheetModal(for: window, completionHandler: finish); window.makeFirstResponder(field) }
    else { finish(alert.runModal()) }
  }

}
