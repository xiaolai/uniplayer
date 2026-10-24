import AppKit
import WebKit
import XCTest
@testable import UniPlayer

private final class RatingURLProtocol: URLProtocol {
  static var responses: [[String: Any]] = []
  static var requestCount = 0
  static var parameters: [[String: String]] = []
  static var delay: TimeInterval = 0
  static var netflixHTML: String?
  static var netflixURL: URL?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requestCount += 1
    Self.parameters.append(Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name != "apikey" }.map { ($0.name, $0.value ?? "") }))
    let netflix = request.url?.host == "www.netflix.com"
    let json = netflix ? [:] : Self.responses.isEmpty ? ["Response": "False", "Error": "Movie not found!"] : Self.responses.removeFirst()
    let data = netflix ? Data((Self.netflixHTML ?? "").utf8) : try! JSONSerialization.data(withJSONObject: json)
    let url = netflix ? Self.netflixURL ?? request.url! : request.url!
    let deliver = {
      self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
        httpVersion: nil, headerFields: ["Content-Type": netflix ? "text/html" : "application/json"])!, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    if Self.delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: deliver) }
    else { deliver() }
  }

  override func stopLoading() {}
}

@MainActor
final class NetflixRatingLookupTests: XCTestCase {
  private func query(_ title: String = "Example", id: String = "80000001", hints: Bool = false) -> NetflixRatingQuery {
    var body = ["id": id, "title": title]
    if hints { body["year"] = "2020"; body["type"] = "movie" }
    return NetflixRatingQuery(body: body)!
  }
  private func service(cacheURL: URL? = nil, overrideURL: URL? = nil, now: @escaping () -> Date = Date.init) -> NetflixRatingService {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RatingURLProtocol.self]
    RatingURLProtocol.requestCount = 0; RatingURLProtocol.parameters = []; RatingURLProtocol.responses = []; RatingURLProtocol.delay = 0
    return NetflixRatingService(session: URLSession(configuration: config), cacheURL: cacheURL,
      overrideURL: overrideURL, identityURL: nil, now: now, credential: { "fixture-only" })
  }
  private var match: [String: Any] {
    ["Response": "True", "totalResults": "1", "Search": [["Title": "Example", "imdbID": "tt1234567", "Type": "movie", "Year": "2020"]]]
  }
  private var detail: [String: Any] {
    ["Response": "True", "Title": "Example", "Year": "2020", "Type": "movie", "imdbID": "tt1234567", "imdbRating": "9.3", "imdbVotes": "12,345"]
  }

  func testVoteFormattingAndValidation() {
    XCTAssertEqual(NetflixRating(imdbID: "tt1234567", score: 9.3, votes: 12000).badge, "9.3 (12K)")
    for (votes, text) in [(999, "999"), (1200, "1.2K"), (999999, "1M"), (1200000, "1.2M")] {
      XCTAssertEqual(NetflixRating.voteCount(votes), text)
    }
    XCTAssertNil(NetflixRatingQuery(body: ["id": "../bad", "title": "Example"]))
    XCTAssertNil(NetflixRatingQuery(body: ["id": "123", "title": "  "]))
    XCTAssertNotNil(NetflixRatingQuery(body: ["title": "A semantic card without a link"]))
    XCTAssertFalse(NetflixRatingService.validIMDbID("tt1234567/javascript"))
    XCTAssertEqual(NetflixRatingService.parsedIMDbID("https://www.imdb.com/title/tt1234567/?ref_=x"), "tt1234567")
    XCTAssertNil(NetflixRatingService.parsedIMDbID("https://imdb.com.evil.example/title/tt1234567/"))
    XCTAssertTrue(NetflixRatingsBridge.isNetflix(URL(string: "https://www.netflix.com/browse")))
    XCTAssertFalse(NetflixRatingsBridge.isNetflix(URL(string: "https://netflix.com.attacker.example")))
    XCTAssertFalse(NetflixRatingsBridge.isNetflix(URL(string: "http://www.netflix.com")))
  }

  func testColdTitleIsOneDirectLookupAndPersistentCacheNeedsNoKey() async throws {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let lookup = service(cacheURL: cache); RatingURLProtocol.responses = [detail]
    let result = await lookup.lookup(query())
    XCTAssertEqual(result?.badge, "9.3 (12.3K)"); XCTAssertEqual(result?.verified, false)
    let again = await lookup.lookup(query()); XCTAssertEqual(again, result)
    XCTAssertEqual(RatingURLProtocol.requestCount, 1)
    XCTAssertEqual(RatingURLProtocol.parameters, [["t": "Example"]])
    let restored = NetflixRatingService(cacheURL: cache, overrideURL: nil, identityURL: nil, credential: { nil })
    let stored = await restored.lookup(query()); XCTAssertEqual(stored, result)
    XCTAssertFalse(try String(contentsOf: cache, encoding: .utf8).contains("fixture-only"))
  }

  func testYearAndFormatProveUniqueMatchAndWrongMetadataIsRejected() async {
    let lookup = service(); RatingURLProtocol.responses = [match, detail]
    let result = await lookup.lookup(query(hints: true)); XCTAssertEqual(result?.verified, true)
    XCTAssertEqual(RatingURLProtocol.parameters.first, ["s": "Example", "y": "2020", "type": "movie"])
    var wrong = detail; wrong["Year"] = "2019"
    RatingURLProtocol.responses = [match, wrong]
    let rejected = await lookup.lookup(query(id: "80000002", hints: true)); XCTAssertNil(rejected)
  }

  func testHoverHintsUpgradeCachedCandidateWithoutFetchingDetailsAgain() async {
    let lookup = service(); RatingURLProtocol.responses = [detail]
    _ = await lookup.lookup(query())
    RatingURLProtocol.responses = [match]
    let result = await lookup.outcome(query(hints: true), force: true)
    XCTAssertEqual(result.rating?.verified, true)
    XCTAssertEqual(RatingURLProtocol.requestCount, 2)
    XCTAssertNotNil(RatingURLProtocol.parameters.last?["s"])
  }

  func testAmbiguousAndPartialSearchResultsRemainUnverified() async {
    let lookup = service(); var ambiguous = match
    ambiguous["totalResults"] = "2"
    ambiguous["Search"] = [["Title": "Example", "imdbID": "tt1234567", "Type": "movie", "Year": "2020"],
                           ["Title": "Example", "imdbID": "tt1234568", "Type": "movie", "Year": "2020"]]
    RatingURLProtocol.responses = [ambiguous, detail]
    let result = await lookup.lookup(query(hints: true)); XCTAssertEqual(result?.verified, false)
    var partial = match; partial["totalResults"] = "20"
    RatingURLProtocol.responses = [partial, detail]
    let other = await lookup.lookup(query(id: "80000002", hints: true)); XCTAssertEqual(other?.verified, false)
  }

  func testUnratedWrongTitlesAndMissingTitlesStayUnlabelled() async {
    let lookup = service(); var wrong = detail; wrong["Title"] = "Another Film"
    RatingURLProtocol.responses = [wrong]
    let result = await lookup.lookup(query()); XCTAssertNil(result)
    var unrated = detail; unrated["imdbRating"] = "N/A"
    RatingURLProtocol.responses = [unrated]
    let other = await lookup.lookup(query(id: "80000002")); XCTAssertNil(other)
    let missing = await lookup.outcome(query(id: "80000003")); XCTAssertEqual(missing.state, "notFound")
  }

  func testCredentialAndQuotaFailuresAreRetryableNotNegativeCached() async {
    let lookup = service()
    for error in ["Invalid API key!", "Request limit reached!"] {
      RatingURLProtocol.responses = [["Response": "False", "Error": error]]
      let failed = await lookup.outcome(query()); XCTAssertEqual(failed.state, "retry")
      let count = RatingURLProtocol.requestCount
      _ = await lookup.outcome(query(id: "80000002")); XCTAssertEqual(RatingURLProtocol.requestCount, count)
      lookup.configurationChanged(); RatingURLProtocol.responses = [detail]
      let result = await lookup.lookup(query()); XCTAssertNotNil(result)
      lookup.configurationChanged()
      // Use another ID to avoid testing the positive cache on the next iteration.
      try? lookup.saveOverride(nil, for: "80000001")
    }
  }

  func testExpiredCacheDisplaysImmediatelyAndRefreshes() async {
    var clock = Date(); let lookup = service(now: { clock }); RatingURLProtocol.responses = [detail]
    _ = await lookup.lookup(query()); clock = clock.addingTimeInterval(8 * 24 * 3600)
    var refreshed = detail; refreshed["imdbRating"] = "9.4"; RatingURLProtocol.responses = [refreshed]
    let stale = await lookup.outcome(query()); XCTAssertTrue(stale.stale); XCTAssertEqual(stale.rating?.score, 9.3)
    for _ in 0..<50 {
      if RatingURLProtocol.requestCount == 2 { break }; try? await Task.sleep(for: .milliseconds(10))
    }
    var fresh = await lookup.outcome(query())
    for _ in 0..<50 {
      if fresh.rating?.score == 9.4 { break }; try? await Task.sleep(for: .milliseconds(10)); fresh = await lookup.outcome(query())
    }
    XCTAssertEqual(fresh.rating?.score, 9.4); XCTAssertEqual(RatingURLProtocol.requestCount, 2)
    let changed = await lookup.lookup(query("Changed Title")); XCTAssertNil(changed)
  }

  func testSavedCorrectionPersistsByNetflixIDAndCanBeCleared() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let lookup = service(overrideURL: path)
    try lookup.saveOverride("tt7654321", for: "80000001")
    var corrected = detail; corrected["imdbID"] = "tt7654321"; corrected["Title"] = "Original Language Title"
    RatingURLProtocol.responses = [corrected, detail]
    let saved = await lookup.lookup(query()); XCTAssertEqual(saved?.userConfirmed, true); XCTAssertEqual(saved?.verified, true)
    XCTAssertEqual(RatingURLProtocol.parameters.first, ["i": "tt7654321"])
    let unrelated = await lookup.lookup(query(id: "80000002")); XCTAssertEqual(unrelated?.userConfirmed, false)
    let restored = NetflixRatingService(cacheURL: nil, overrideURL: path, identityURL: nil, credential: { nil })
    XCTAssertEqual(restored.override(for: "80000001"), "tt7654321"); XCTAssertNil(restored.override(for: "80000002"))
    try lookup.saveOverride(nil, for: "80000001"); XCTAssertNil(lookup.override(for: "80000001"))
    RatingURLProtocol.responses = [detail]
    let automatic = await lookup.lookup(query()); XCTAssertEqual(automatic?.imdbID, "tt1234567"); XCTAssertEqual(automatic?.verified, false)
  }

  func testBudgetDefersThenRecoversAndCacheReadsHaveNoPageCap() async {
    var clock = Date(); let lookup = service(now: { clock })
    RatingURLProtocol.responses = Array(repeating: detail, count: 61)
    for id in 1...60 { let result = await lookup.outcome(query(id: String(id))); XCTAssertEqual(result.state, "ready") }
    let deferred = await lookup.outcome(query(id: "61")); XCTAssertEqual(deferred.state, "retry"); XCTAssertEqual(deferred.reason, "deferred")
    for _ in 0..<210 { _ = await lookup.outcome(query(id: "1")) }
    XCTAssertEqual(RatingURLProtocol.requestCount, 60)
    clock = clock.addingTimeInterval(61)
    let recovered = await lookup.outcome(query(id: "61")); XCTAssertEqual(recovered.state, "ready"); XCTAssertEqual(RatingURLProtocol.requestCount, 61)
  }

  func testConcurrentQueueCompletesInsteadOfDroppingCards() async {
    let lookup = service(); RatingURLProtocol.responses = Array(repeating: detail, count: 12)
    let results = await withTaskGroup(of: String.self) { group in
      for id in 1...12 { let q = query(id: String(id)); group.addTask { await lookup.outcome(q).state } }
      var states: [String] = []; for await state in group { states.append(state) }; return states
    }
    XCTAssertEqual(results.count, 12); XCTAssertTrue(results.allSatisfy { $0 == "ready" }); XCTAssertEqual(RatingURLProtocol.requestCount, 12)
  }

  func testEpisodeResolvesAndPersistsCanonicalSeriesIdentity() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RatingURLProtocol.self]
    RatingURLProtocol.delay = 0; RatingURLProtocol.requestCount = 0; RatingURLProtocol.parameters = []
    RatingURLProtocol.netflixHTML = "<html><body><h1>Example &amp; Friends</h1><ul><li>2020</li><li>2 Seasons</li></ul></body></html>"
    RatingURLProtocol.netflixURL = URL(string: "https://www.netflix.com/title/80000001")
    var series = detail; series["Title"] = "Example & Friends"; series["Type"] = "series"
    RatingURLProtocol.responses = [series, series]
    func resolver() -> NetflixRatingService {
      NetflixRatingService(session: URLSession(configuration: config), cacheURL: nil, overrideURL: nil, identityURL: path, credential: { "fixture-only" })
    }
    let q = NetflixRatingQuery(body: ["id": "80000002", "title": "Pilot", "episode": true])!
    let first = await resolver().lookup(q); XCTAssertEqual(first?.matchedTitle, "Example & Friends")
    let restored = await resolver().lookup(q); XCTAssertEqual(restored?.imdbID, "tt1234567")
    XCTAssertEqual(RatingURLProtocol.requestCount, 3) // One public show resolution, two OMDb lookups.
    XCTAssertEqual(RatingURLProtocol.parameters.last, ["t": "Example & Friends", "type": "series"])
    RatingURLProtocol.netflixHTML = nil; RatingURLProtocol.netflixURL = nil
  }

  func testOldQueryCacheDecodesWithoutEpisodeField() throws {
    let data = Data(#"{"netflixID":"123","title":"Example","year":null,"type":null}"#.utf8)
    XCTAssertFalse(try JSONDecoder().decode(NetflixRatingQuery.self, from: data).episode)
  }
}

@MainActor
private final class RatingDOMReply: NSObject, WKScriptMessageHandlerWithReply {
  var opens = 0
  var lookups = 0
  var titles: [String] = []
  var disabled = false
  var bodies: [[String: Any]] = []
  var custom: (([String: Any], Int) -> [String: Any])?
  var edits = 0
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    let body = message.body as! [String: Any]
    if body["action"] as? String == "editMatch" { edits += 1; bodies.append(body); replyHandler(["changed": false], nil); return }
    if body["action"] as? String == "search" { replyHandler(["ok": true], nil); return }
    if body["action"] as? String == "open" { opens += 1; replyHandler(["ok": true], nil); return }
    lookups += 1; bodies.append(body)
    titles.append(body["title"] as? String ?? "")
    if disabled { replyHandler(["disabled": true], nil); return }
    if let custom { replyHandler(custom(body, lookups), nil); return }
    replyHandler(["badge": "9.3 (12K)", "score": 9.3, "votes": 12000, "imdbID": "tt1234567", "verified": true], nil)
  }
}

@MainActor
final class NetflixRatingDOMTests: XCTestCase {
  private func waitFor(_ js: String, web: WKWebView, seconds: Double = 6) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if (try? await web.evaluateJavaScript(js)) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Netflix card fixture did not reach expected DOM state: \(js)")
  }

  private func fixture(_ html: String, reply: RatingDOMReply) -> (WKWebView, NSWindow) {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.userContentController.addScriptMessageHandler(reply, contentWorld: NetflixRatingsBridge.world, name: "netflixRatings")
    config.userContentController.addUserScript(WKUserScript(source: NetflixRatingsBridge.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: NetflixRatingsBridge.world))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    web.loadHTMLString("<html><head><style>.title-card,[data-uia$='-card'],.previewModal--player_container {width:260px;height:150px;display:inline-block} .previewModal--wrapper{display:inline-block}</style></head><body>" + html + "</body></html>", baseURL: URL(string: "https://www.netflix.com/browse"))
    return (web, window)
  }

  func testAllSixReviewedSurfaceShapesIncludingNonAnchorCardsAndPreviews() async throws {
    // Independently authored markup representing the six reviewed surface contracts.
    let reply = RatingDOMReply()
    let (web, window) = fixture("""
      <div class="title-card-container"><div class="title-card"><a href="/watch/80000001" aria-label="Legacy"><div class="boxart-container"></div></a></div></div>
      <div data-uia="standard-card" aria-label="Search"><div class="boxart-container"></div></div>
      <div data-uia="progress-card" aria-label="Progress"><div class="boxart-container"></div></div>
      <div data-uia="ranked-card" aria-label="Ranked"><div class="boxart-container"></div><span class="ranked-card-badge">TOP 10</span></div>
      <div class="previewModal--wrapper mini-modal"><div class="previewModal--player_container"><img alt="Mini Preview"></div></div>
      <div class="previewModal--wrapper detail-modal"><div class="previewModal--player_container"><img alt="Detail Preview"></div></div>
      """, reply: reply)
    defer { window.close(); web.configuration.userContentController.removeAllScriptMessageHandlers() }
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating[data-state=verified]').length === 6", web: web)
    XCTAssertEqual(Set(reply.titles), Set(["Legacy", "Search", "Progress", "Ranked", "Mini Preview", "Detail Preview"]))
    XCTAssertEqual(reply.lookups, 6)
    let original = try await web.evaluateJavaScript("document.querySelector('.ranked-card-badge').textContent") as? String
    XCTAssertEqual(original, "TOP 10")
    let hidden = try await web.evaluateJavaScript("document.querySelector('[data-uia=standard-card] .uniplayer-imdb-edit').hidden") as? Bool
    XCTAssertEqual(hidden, true) // No invented Netflix ID for div-only cards.
  }

  func testHoverEnrichmentUsesNetflixIDAndRecycledPreviewDoesNotLeakIdentity() async throws {
    let reply = RatingDOMReply()
    let (web, window) = fixture("""
      <div class="title-card" id="a"><a href="/watch/80000001" aria-label="Example"></a></div>
      <div class="title-card" id="b"><a href="/watch/80000002" aria-label="Example"></a></div>
      """, reply: reply)
    defer { window.close(); web.configuration.userContentController.removeAllScriptMessageHandlers() }
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating[data-state=verified]').length === 2", web: web)
    _ = try await web.evaluateJavaScript("""
      document.querySelector('#a').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
      document.body.insertAdjacentHTML('beforeend',`<div class="previewModal--wrapper mini-modal"><div class="previewModal--player_container"><img alt="Example"></div><div class="previewModal--metadatAndControls-container"><span data-uia="makeover-content-type-genre">Movie | Drama</span><span data-uia="makeover-metadata">2020 • 2h</span></div></div>`)
      """)
    try await waitFor("document.querySelector('#a .uniplayer-imdb-rating')?.dataset.query.includes('2020') === true", web: web)
    let b = try await web.evaluateJavaScript("document.querySelector('#b .uniplayer-imdb-rating').dataset.query") as! String
    XCTAssertFalse(b.contains("2020"))
    XCTAssertTrue(reply.bodies.contains { $0["id"] as? String == "80000001" && $0["year"] as? String == "2020" })
    _ = try await web.evaluateJavaScript("""
      document.querySelector('#b').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
      document.querySelector('[data-uia=makeover-metadata]').textContent='2021';
      """)
    try await waitFor("document.querySelector('#b .uniplayer-imdb-rating')?.dataset.query.includes('2021') === true", web: web)
    let a = try await web.evaluateJavaScript("document.querySelector('#a .uniplayer-imdb-rating').dataset.query") as! String
    XCTAssertFalse(a.contains("2021"))
    _ = try await web.evaluateJavaScript("document.querySelector('#b .uniplayer-imdb-edit').click()")
    for _ in 0..<20 { if reply.edits == 1 { break }; try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(reply.edits, 1); XCTAssertEqual(reply.bodies.last?["id"] as? String, "80000002")
  }

  func testSeriesDetailLatestSeasonYearIsNotUsedAsOriginalReleaseYear() async throws {
    let reply = RatingDOMReply()
    let (web, window) = fixture("""
      <div class="previewModal--wrapper detail-modal" data-videoid="80000001">
      <div class="previewModal--player_container"><img alt="Example"></div>
      <div class="previewModal--info"><div data-uia="videoMetadata--container">2026 • 5 Seasons</div><select data-uia="episode-selector"></select></div></div>
      """, reply: reply)
    defer { window.close(); web.configuration.userContentController.removeAllScriptMessageHandlers() }
    try await waitFor("document.querySelector('.uniplayer-imdb-rating[data-state=verified]') !== null", web: web)
    XCTAssertEqual(reply.bodies.first?["type"] as? String, "series"); XCTAssertNil(reply.bodies.first?["year"])
  }

  func testTransientFailureRetriesAndSPAChangeKeepsBadges() async throws {
    let reply = RatingDOMReply()
    reply.custom = { _, count in count == 1 ? ["state": "retry", "reason": "network", "retryAfter": 0.1] :
      ["badge": "9.3 (12K)", "score": 9.3, "votes": 12000, "imdbID": "tt1234567", "verified": false] }
    let (web, window) = fixture("<div data-uia='standard-card' aria-label='Example' data-videoid='80000001'></div>", reply: reply)
    defer { window.close(); web.configuration.userContentController.removeAllScriptMessageHandlers() }
    try await waitFor("document.querySelector('.uniplayer-imdb-rating[data-state=unverified]') !== null", web: web)
    XCTAssertEqual(reply.lookups, 2)
    _ = try await web.evaluateJavaScript("history.pushState({},'', '/browse?jbv=80000001')")
    try await Task.sleep(for: .milliseconds(1200))
    let count = try await web.evaluateJavaScript("document.querySelectorAll('.uniplayer-imdb-rating').length") as? Int
    XCTAssertEqual(count, 1)
    XCTAssertEqual(reply.lookups, 2)
  }

  func testDynamicCardsDeduplicateRemoveStaleBadgesAndPreserveClicks() async throws {
    let reply = RatingDOMReply()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.addScriptMessageHandler(reply, contentWorld: NetflixRatingsBridge.world, name: "netflixRatings")
    config.userContentController.addUserScript(WKUserScript(source: NetflixRatingsBridge.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: NetflixRatingsBridge.world))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "Netflix Ratings Fixture"
    window.contentView = web; window.orderBack(nil)
    defer { window.close(); config.userContentController.removeAllScriptMessageHandlers() }
    web.loadHTMLString("""
      <html><head><style>.title-card {width:300px;height:170px;background:#333;margin:10px;}</style></head><body>
      <div class="title-card-container"><div class="title-card" id="first"><a href="/watch/80000001" onclick="window.movieClicks++; return false"><span class="fallback-text">Example</span></a></div></div>
      <div class="title-card" id="duplicate"><a href="/watch/80000001"><span class="fallback-text">Example</span></a></div>
      <div class="title-card" id="later" style="margin-top:900px"><a href="/watch/80000002"><span class="fallback-text">Later</span></a></div>
      <script>window.movieClicks=0</script></body></html>
      """, baseURL: URL(string: "https://www.netflix.com/browse"))
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating[data-state=verified]').length === 2", web: web)
    XCTAssertEqual(reply.lookups, 1)
    let badge = try await web.evaluateJavaScript("document.querySelector('.uniplayer-imdb-rating').textContent") as? String
    XCTAssertEqual(badge, "9.3 (12K)")
    let visibleAtTopRight = try await web.evaluateJavaScript("""
      (() => { const card=document.querySelector('#first').getBoundingClientRect();
        const badge=document.querySelector('#first .uniplayer-imdb-rating'); const b=badge.getBoundingClientRect();
        return Math.abs(b.top-card.top)<2 && Math.abs(b.right-card.right)<2 && b.width>=110 && b.height>=30
          && badge.querySelector('svg')!==null; })()
      """) as? Bool
    XCTAssertEqual(visibleAtTopRight, true)
    let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: nil) { image, error in
        if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: error ?? URLError(.unknown)) }
      }
    }
    let attachment = XCTAttachment(image: snapshot)
    attachment.name = "Netflix rating badge fixture"
    attachment.lifetime = .keepAlways
    add(attachment)
    _ = try await web.evaluateJavaScript("document.querySelector('.uniplayer-imdb-rating').click()")
    try await waitFor("window.movieClicks === 0", web: web)
    XCTAssertEqual(reply.opens, 1)
    _ = try await web.evaluateJavaScript("document.querySelector('#first a').click(); document.querySelector('#first a').onclick=null")
    try await waitFor("window.movieClicks === 1", web: web)
  }

  func testModernNetflixBrowseQueryCardsWithoutLegacyClasses() async throws {
    let reply = RatingDOMReply()
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.userContentController.addScriptMessageHandler(reply, contentWorld: NetflixRatingsBridge.world, name: "netflixRatings")
    config.userContentController.addUserScript(WKUserScript(source: NetflixRatingsBridge.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: NetflixRatingsBridge.world))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { window.close(); config.userContentController.removeAllScriptMessageHandlers() }
    web.loadHTMLString("""
      <div class="carousel-row">
      <a class="generated-card" href="/browse?jbv=80000001" aria-label="Example" style="display:block;width:300px;height:170px;position:absolute"><img alt="Season 3"></a>
      </div>
      <a href="/browse?jbv=80000002">More Info</a>
      """, baseURL: URL(string: "https://www.netflix.com/browse"))
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating[data-state=verified]').length === 1", web: web)
    XCTAssertEqual(reply.lookups, 1)
    XCTAssertEqual(reply.titles, ["Example"])
    let position = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.generated-card')).position") as? String
    XCTAssertEqual(position, "absolute")
    _ = try await web.evaluateJavaScript("document.querySelector('.generated-card').href='/browse'")
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating').length === 0", web: web)
  }

  func testScrollAndCardReuseAndDisable() async throws {
    let reply = RatingDOMReply()
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.userContentController.addScriptMessageHandler(reply, contentWorld: NetflixRatingsBridge.world, name: "netflixRatings")
    config.userContentController.addUserScript(WKUserScript(source: NetflixRatingsBridge.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: NetflixRatingsBridge.world))
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { window.close(); config.userContentController.removeAllScriptMessageHandlers() }
    web.loadHTMLString("""
      <div style="height:1000px">Scroll fixture</div>
      <div class="title-card" style="height:180px;width:300px"><a href="/watch/80000001"><span class="fallback-text">Example</span></a></div>
      """, baseURL: URL(string: "https://www.netflix.com/browse"))
    try await waitFor("document.querySelector('.title-card') !== null", web: web)
    _ = try await web.evaluateJavaScript("document.querySelector('.title-card').scrollIntoView()")
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating[data-state=verified]').length === 1", web: web)
    _ = try await web.evaluateJavaScript("document.querySelector('.title-card a').href='/watch/80000002'; document.querySelector('.fallback-text').textContent='Reused'")
    try await waitFor("document.querySelector('.uniplayer-imdb-rating[data-state=verified]')?.dataset.query.includes('80000002') === true", web: web)
    XCTAssertEqual(reply.lookups, 2)
    reply.disabled = true
    _ = try await web.evaluateJavaScript("globalThis.uniPlayerRatings.reset()", in: nil, contentWorld: NetflixRatingsBridge.world)
    try await waitFor("document.querySelectorAll('.uniplayer-imdb-rating').length === 0", web: web)
  }
}

final class NetflixTitleMetadataTests: XCTestCase {
  func testPublicSeriesMetadataUsesYearAndFormatWithoutGeneratedClasses() {
    let html = "<html><body><ul><li>Home</li></ul><ul class='generated'><li>2020</li><li>Limited Series</li><li>16+</li></ul></body></html>"
    XCTAssertEqual(NetflixTitleMetadata.parse(html), NetflixTitleMetadata(year: "2020", type: "series"))
  }
  func testMovieAndMultipartSeriesMetadata() {
    XCTAssertEqual(NetflixTitleMetadata.parse("<body><ul><li><span>2018</span></li><li>1h 28m</li></ul>"), NetflixTitleMetadata(year: "2018", type: "movie"))
    XCTAssertEqual(NetflixTitleMetadata.parse("<body><ul><li>2021</li><li>3 Parts</li></ul>"), NetflixTitleMetadata(year: "2021", type: "series"))
  }
  func testMaturityAndUnrelatedListsCannotBecomeAReleaseYear() {
    XCTAssertNil(NetflixTitleMetadata.parse("<body><ul><li>16+</li><li>Drama</li></ul>"))
    XCTAssertNil(NetflixTitleMetadata.parse("<body><ul><li>2020</li><li>Privacy</li></ul>"))
    XCTAssertNil(NetflixTitleMetadata.parse("<body><ul><li>9999</li><li>1h 20m</li></ul>"))
  }
}

@MainActor
final class NetflixRatingBridgeTests: XCTestCase {
  func testSPARepliesSurviveButNewDocumentRepliesAreInvalidatedAndCorrectionsSave() async throws {
    let previous = UserDefaults.standard.object(forKey: NetflixRatingService.enabledKey)
    UserDefaults.standard.set(true, forKey: NetflixRatingService.enabledKey)
    defer { UserDefaults.standard.set(previous, forKey: NetflixRatingService.enabledKey) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RatingURLProtocol.self]
    let service = NetflixRatingService(session: URLSession(configuration: config), cacheURL: nil, overrideURL: nil, identityURL: nil, credential: { "fixture-only" })
    let bridge = NetflixRatingsBridge(service: service)
    let webConfig = WKWebViewConfiguration(); webConfig.websiteDataStore = .nonPersistent(); bridge.install(in: webConfig)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: webConfig); bridge.attach(to: web)
    defer { webConfig.userContentController.removeAllScriptMessageHandlers(); RatingURLProtocol.delay = 0 }
    web.loadHTMLString("<html><body>Bridge contract fixture</body></html>", baseURL: URL(string: "https://www.netflix.com/browse"))
    func wait(_ expression: String, isolated: Bool = false) async throws {
      for _ in 0..<100 {
        let value = isolated ? try? await web.evaluateJavaScript(expression, in: nil, contentWorld: NetflixRatingsBridge.world) : try? await web.evaluateJavaScript(expression)
        if value as? Bool == true { return }; try await Task.sleep(for: .milliseconds(20))
      }
      let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({reply:globalThis.contractReply,edit:globalThis.editReply,url:location.href})", in: nil, contentWorld: NetflixRatingsBridge.world)
      XCTFail("Bridge fixture did not reach expected state: " + expression + " " + String(describing: diagnostic))
    }
    try await wait("document.body?.textContent.includes('Bridge contract') === true")
    let detail: [String: Any] = ["Response": "True", "Title": "Example", "Year": "2020", "Type": "movie", "imdbID": "tt1234567", "imdbRating": "9.3", "imdbVotes": "12,000"]
    RatingURLProtocol.responses = [detail]; RatingURLProtocol.delay = 0.2
    _ = try await web.evaluateJavaScript("webkit.messageHandlers.netflixRatings.postMessage({id:'81000001',title:'Example'}).then(r=>globalThis.contractReply=r).catch(e=>globalThis.contractReply={error:String(e)});null", in: nil, contentWorld: NetflixRatingsBridge.world)
    _ = try await web.evaluateJavaScript("history.pushState({},'', '/browse?jbv=81000001')")
    try await wait("globalThis.contractReply?.state === 'ready'", isolated: true)
    RatingURLProtocol.responses = [detail]
    _ = try await web.evaluateJavaScript("globalThis.contractReply=null;webkit.messageHandlers.netflixRatings.postMessage({id:'81000002',title:'Example'}).then(r=>globalThis.contractReply=r).catch(e=>globalThis.contractReply={error:String(e)});null", in: nil, contentWorld: NetflixRatingsBridge.world)
    try await Task.sleep(for: .milliseconds(50)); bridge.navigationStarted()
    try await wait("globalThis.contractReply?.reason === 'navigation'", isolated: true)
    var editedID = ""
    bridge.presentMatchEditor = { query, _, finish in editedID = query.netflixID; finish(.save("tt7654321")) }
    _ = try await web.evaluateJavaScript("globalThis.editReply=null;webkit.messageHandlers.netflixRatings.postMessage({action:'editMatch',id:'81000001',title:'Example'}).then(r=>globalThis.editReply=r).catch(e=>globalThis.editReply={error:String(e)});null", in: nil, contentWorld: NetflixRatingsBridge.world)
    try await wait("globalThis.editReply?.changed === true", isolated: true)
    XCTAssertEqual(editedID, "81000001"); XCTAssertEqual(service.override(for: editedID), "tt7654321")
  }
}
