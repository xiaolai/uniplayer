//
//  AssistantCompanionTests.swift
//  UniPlayerTests
//

import XCTest
@testable import UniPlayer

final class DialogueBufferTests: XCTestCase {
  func testLinesKeepTheirTimestampAndDropDuplicates() {
    var buffer = DialogueBuffer()
    buffer.append(text: "  First line.  ", position: 12)
    buffer.append(text: "First line.", position: 13)
    buffer.append(text: "Second line.", position: 14)

    XCTAssertEqual(buffer.lines.map(\.text), ["First line.", "Second line."])
    XCTAssertEqual(buffer.lines.first?.timestamp, "00:12")
    XCTAssertTrue(buffer.formatted.contains("[00:14] Second line."))
  }

  func testBufferIsBoundedByCharactersAndLines() {
    var characters = DialogueBuffer()
    for index in 0..<80 {
      characters.append(
        text: String(format: "%03d", index) + String(repeating: "x", count: 97),
        position: Double(index))
    }
    XCTAssertLessThanOrEqual(characters.characterCount, DialogueBuffer.maxCharacters)
    XCTAssertGreaterThan(characters.characterCount, 0)
    XCTAssertLessThan(characters.lines.count, DialogueBuffer.maxLines)

    var lines = DialogueBuffer()
    for index in 0..<60 {
      lines.append(text: "Line \(index)", position: Double(index))
    }
    XCTAssertEqual(lines.lines.count, DialogueBuffer.maxLines)
    XCTAssertLessThanOrEqual(lines.characterCount, DialogueBuffer.maxCharacters)
  }

  func testResetClearsTheWindow() {
    var buffer = DialogueBuffer()
    buffer.append(text: "One", position: 1)
    buffer.reset()
    XCTAssertTrue(buffer.lines.isEmpty)
    XCTAssertEqual(buffer.characterCount, 0)
    XCTAssertTrue(buffer.formatted.isEmpty)
  }

  func testRepeatedLineAfterAnEmptyEventKeepsBothOccurrences() {
    var buffer = DialogueBuffer()
    buffer.append(text: "Yes", position: 10)
    buffer.append(text: "", position: 11)
    buffer.append(text: "Yes", position: 30)

    XCTAssertEqual(buffer.lines.map(\.position), [10, 30])
  }

  func testClippedDuplicateDoesNotChangeTheOriginalTimestamp() {
    var buffer = DialogueBuffer()
    let long = String(repeating: "x", count: 1_600)
    buffer.append(text: long, position: 10)
    buffer.append(text: long, position: 20)

    XCTAssertEqual(buffer.lines.count, 1)
    XCTAssertEqual(buffer.lines.first?.position, 10)
    XCTAssertEqual(buffer.characterCount, DialogueBuffer.maxCharacters)
  }

  func testRecentWindowDropsDialogueAfterABackwardSeek() {
    var buffer = DialogueBuffer()
    for position in [10.0, 100, 300] {
      buffer.append(text: "Line \(Int(position))", position: position)
    }

    XCTAssertEqual(buffer.recent(endingAt: 100).map(\.position), [10, 100])
  }
}

final class AssistantContextV2Tests: XCTestCase {
  private let metadata = LibraryMetadata(
    title: "Example Show", year: 2024, season: 2, episode: 3, quality: "1080p")

  func testDisclosureCarriesIdentityPlaybackStateAndRecentDialogue() {
    let snapshot = PlayerSnapshot(
      title: "Example.Show.S02E03.1080p.mkv",
      url: URL(fileURLWithPath: "/tmp/Example.Show.S02E03.1080p.mkv"),
      isNetwork: false,
      position: 125,
      duration: 600,
      speed: 1.25,
      audioTrack: "English",
      subtitleTrack: "English",
      subtitleLine: "  Look at that.  ",
      isPaused: true,
      metadata: metadata,
      recentDialogue: [
        DialogueLine(position: 110, text: "Who is that?"),
        DialogueLine(position: 120, text: "An old friend."),
      ])

    let context = PlaybackContextBuilder.make(snapshot: snapshot, options: .init())

    XCTAssertTrue(context.disclosure.contains("Media: Example Show · 2024 · S02E03 · 1080p"))
    XCTAssertTrue(context.disclosure.contains("State: paused"))
    XCTAssertTrue(context.disclosure.contains("[01:50] Who is that?"))
    XCTAssertTrue(context.disclosure.contains("Recent dialogue:"))
    XCTAssertEqual(context.subtitleLine, "Look at that.")
  }

  func testSelectionAndSubtitleAreCapped() {
    let snapshot = PlayerSnapshot(
      title: "Movie.mkv", url: URL(fileURLWithPath: "/tmp/Movie.mkv"),
      isNetwork: false, position: 1, duration: 2, speed: 1,
      audioTrack: nil, subtitleTrack: nil,
      subtitleLine: String(repeating: "s", count: 900))
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot,
      options: .init(selection: String(repeating: "q", count: 3_000)))

    XCTAssertEqual(context.subtitleLine?.count, 500)
    XCTAssertEqual(context.selection?.count, 2_000)
  }

  func testLoadingStateIsDisclosedAsLoading() {
    let snapshot = PlayerSnapshot(
      title: "Movie.mkv", url: URL(fileURLWithPath: "/tmp/Movie.mkv"),
      isNetwork: false, position: nil, duration: nil, speed: 1,
      audioTrack: nil, subtitleTrack: nil, subtitleLine: nil,
      playbackState: .loading)
    let context = PlaybackContextBuilder.make(snapshot: snapshot, options: .init())
    XCTAssertTrue(context.disclosure.contains("State: loading"))
  }

  func testDialogueAfterCurrentPositionIsFiltered() {
    let snapshot = PlayerSnapshot(
      title: "Movie.mkv", url: URL(fileURLWithPath: "/tmp/Movie.mkv"),
      isNetwork: false, position: 100, duration: 600, speed: 1,
      audioTrack: nil, subtitleTrack: nil, subtitleLine: nil,
      recentDialogue: [
        DialogueLine(position: 10, text: "Earlier"),
        DialogueLine(position: 300, text: "Later"),
      ])
    let context = PlaybackContextBuilder.make(snapshot: snapshot, options: .init())
    XCTAssertTrue(context.recentDialogue.contains { $0.text == "Earlier" })
    XCTAssertFalse(context.recentDialogue.contains { $0.text == "Later" })
  }

  func testLibraryMetadataOverridesFileMetadata() {
    let snapshot = PlayerSnapshot(
      title: "Wrong.Name.mkv", url: URL(fileURLWithPath: "/tmp/Wrong.Name.mkv"),
      isNetwork: false, position: nil, duration: nil, speed: 1,
      audioTrack: nil, subtitleTrack: nil, subtitleLine: nil,
      metadata: LibraryMetadata(title: "Wrong", year: nil, season: nil, episode: nil, quality: nil))
    let item = LibraryItem(
      url: URL(fileURLWithPath: "/tmp/Wrong.Name.mkv"),
      title: "Right Title", subtitle: "Library", metadata: metadata,
      duration: 0, progress: 0, added: Date(), isNetwork: false)
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot, options: .init(libraryItem: item))

    XCTAssertEqual(context.media?.title, "Example Show")
    XCTAssertEqual(context.library?.title, "Right Title")
  }
}

final class AssistantResearchPlannerTests: XCTestCase {
  func testReviewQueryFitsTheApiLimitAndNamesTheSites() {
    let metadata = LibraryMetadata(
      title: "A Very Long Title That Keeps Going", year: 2025,
      season: 1, episode: 2, quality: "2160p")
    let query = AssistantResearchPlanner.reviewsQuery(
      title: String(repeating: "Long Title ", count: 20),
      metadata: metadata, continuation: false)

    XCTAssertLessThanOrEqual(query.count, AssistantResearchPlanner.maxQueryLength)
    XCTAssertTrue(query.contains("site:reddit.com"))
    XCTAssertTrue(query.contains("site:letterboxd.com"))
    XCTAssertTrue(query.contains("site:douban.com"))
    XCTAssertTrue(query.contains("S01E02"))
  }

  func testContinuationQueryHasItsOwnIntent() {
    let query = AssistantResearchPlanner.reviewsQuery(
      title: "Example", metadata: nil, continuation: true)
    XCTAssertTrue(query.contains("worth watching"))
  }

  func testClippingCountsUnicodeScalars() {
    let combining = String(repeating: "e\u{301}", count: 200)
    let clipped = AssistantResearchPlanner.clip(combining, toScalarCount: 128)
    XCTAssertEqual(clipped.unicodeScalars.count, 128)
    XCTAssertLessThan(clipped.count, 128)
  }

  func testReviewQueryStaysWithinScalarLimitForCombiningTitle() {
    let query = AssistantResearchPlanner.reviewsQuery(
      title: String(repeating: "e\u{301}", count: 200),
      metadata: LibraryMetadata(title: "x", year: 2025, season: 1, episode: 2, quality: nil),
      continuation: false)
    XCTAssertLessThanOrEqual(query.unicodeScalars.count, AssistantResearchPlanner.maxQueryLength)
    XCTAssertTrue(query.contains("S01E02"))
  }
}

final class AssistantResearchTests: XCTestCase {
  private func configuration() -> AssistantConfiguration {
    AssistantConfiguration(
      provider: .openAICompatible,
      profileID: "deepseek",
      endpoint: "https://api.deepseek.com",
      model: "deepseek-flash",
      apiKey: "test-key")
  }

  private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResearchURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override func setUp() {
    ResearchURLProtocol.reset()
  }

  func testDeepSeekSearchBuildsTheRequestAndParsesSources() async throws {
    ResearchURLProtocol.payload = Data("""
    {"results":[{
      "rerank_score":2.4,
      "title":"A review",
      "url":"https://example.com/review",
      "snippet":"Short excerpt",
      "summary":"Longer summary",
      "content":"",
      "site_name":"Example",
      "site_icon":null,
      "date":"2026-06-01T00:00:00+00:00",
      "authority":3
    }]}
    """.utf8)

    let client = DeepSeekSearchClient(configuration: configuration(), session: session())
    let result = try await client.search(query: "Example 2024 reviews", count: 5)

    XCTAssertEqual(result.sourceCount, 1)
    XCTAssertEqual(result.sources.first?.title, "A review")
    XCTAssertEqual(result.sources.first?.siteName, "Example")
    XCTAssertEqual(result.sources.first?.authority, 3)
    XCTAssertEqual(result.sources.first?.rerankScore, 2.4)
    XCTAssertEqual(ResearchURLProtocol.capturedURL?.path, "/v1/tools/search")
    XCTAssertEqual(ResearchURLProtocol.capturedAuthorization, "Bearer test-key")

    let body = try XCTUnwrap(ResearchURLProtocol.capturedBody)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["query"] as? String, "Example 2024 reviews")
    XCTAssertEqual(object["count"] as? Int, 5)
    XCTAssertEqual(object["need_content"] as? Bool, false)
  }

  func testEmptyTitleFallsBackToTheHost() async throws {
    ResearchURLProtocol.payload = Data("""
    {"results":[{"title":"","url":"https://example.com/review","site_name":null,
      "date":null,"snippet":"s","summary":"m","authority":2,"rerank_score":2}]}
    """.utf8)
    let client = DeepSeekSearchClient(configuration: configuration(), session: session())
    let result = try await client.search(query: "Example", count: 1)
    XCTAssertEqual(result.sources.first?.title, "example.com")
  }

  func testCrossOriginRedirectIsRefused() async {
    ResearchURLProtocol.redirectURL = URL(string: "https://evil.example/tools/search")
    let client = DeepSeekSearchClient(configuration: configuration(), session: session())
    do {
      _ = try await client.search(query: "Example", count: 1)
      XCTFail("Expected redirectRefused")
    } catch let error as AssistantResearchError {
      XCTAssertEqual(error, .redirectRefused)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testUnauthorizedIsReportedWithoutLeakingTheKey() async {
    ResearchURLProtocol.status = 401
    let client = DeepSeekSearchClient(configuration: configuration(), session: session())

    do {
      _ = try await client.search(query: "Example", count: 5)
      XCTFail("Expected unauthorized")
    } catch let error as AssistantResearchError {
      XCTAssertEqual(error, .unauthorized)
      XCTAssertFalse(error.localizedDescription.contains("test-key"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testFormattedResearchStaysWithinItsBudget() {
    let sources = (0..<10).map { index in
      AssistantResearchSource(
        title: "Source \(index)",
        url: URL(string: "https://example.com/\(index)")!,
        siteName: "Example",
        date: "2026-01-01T00:00:00+00:00",
        snippet: "Snippet",
        summary: String(repeating: "summary ", count: 800),
        authority: 3,
        rerankScore: 2)
    }
    let result = AssistantResearchResult(query: "q", sources: sources)
    let formatted = result.formattedForModel

    XCTAssertLessThanOrEqual(formatted.count, AssistantResearchResult.maxContextCharacters)
    XCTAssertTrue(formatted.contains("https://example.com/0"))
  }

  func testSingleOversizedSourceIsTruncatedToTheBudget() {
    let source = AssistantResearchSource(
      title: "Huge",
      url: URL(string: "https://example.com/huge")!,
      siteName: "Example",
      date: nil,
      snippet: "",
      summary: String(repeating: "x", count: 20_000),
      authority: 3,
      rerankScore: 2)
    let result = AssistantResearchResult(query: "q", sources: [source])
    XCTAssertLessThanOrEqual(
      result.formattedForModel.count,
      AssistantResearchResult.maxContextCharacters)
  }
}

final class AssistantPresetTests: XCTestCase {
  private func context(subtitle: String? = nil, dialogue: [DialogueLine] = []) -> PlaybackContext {
    PlaybackContextBuilder.make(
      snapshot: PlayerSnapshot(
        title: "Movie.mkv", url: URL(fileURLWithPath: "/tmp/Movie.mkv"),
        isNetwork: false, position: 10, duration: 60, speed: 1,
        audioTrack: nil, subtitleTrack: nil, subtitleLine: subtitle,
        recentDialogue: dialogue),
      options: .init())
  }

  func testNoContextOffersNoPlayerPresets() {
    XCTAssertTrue(AssistantPreset.allCases.filter {
      $0.isAvailable(player: nil, channel: nil)
    }.isEmpty)
  }

  func testDialogueUnlocksRecapAndSubtitleUnlocksTranslation() {
    let dialogue = [DialogueLine(position: 9, text: "A line")]
    let withDialogue = context(dialogue: dialogue)
    XCTAssertTrue(AssistantPreset.whatsHappening.isAvailable(player: withDialogue, channel: nil))
    XCTAssertTrue(AssistantPreset.recap.isAvailable(player: withDialogue, channel: nil))
    XCTAssertFalse(AssistantPreset.translateLine.isAvailable(player: withDialogue, channel: nil))

    let withSubtitle = context(subtitle: "A line")
    XCTAssertTrue(AssistantPreset.translateLine.isAvailable(player: withSubtitle, channel: nil))
    XCTAssertTrue(AssistantPreset.reviews.isAvailable(player: withSubtitle, channel: nil))
    XCTAssertTrue(AssistantPreset.reviews.usesResearch)
  }

  func testChannelPresetsFollowTheSelection() {
    let channel = ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: nil)
    XCTAssertTrue(AssistantPreset.pageSummary.isAvailable(player: nil, channel: channel))
    XCTAssertFalse(AssistantPreset.pageSelection.isAvailable(player: nil, channel: channel))
    let selected = ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote")
    XCTAssertTrue(AssistantPreset.pageSelection.isAvailable(player: nil, channel: selected))
  }

  func testTranslatePresetNamesTheConfiguredTargetLanguage() {
    let target = SubtitleTranslationSettings.targetLanguage()
    XCTAssertTrue(AssistantPreset.translateLine.prompt.contains(target))
  }

  func testChannelContextHidesPlayerPresets() {
    let player = context(subtitle: "A line", dialogue: [DialogueLine(position: 9, text: "A line")])
    let channel = ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote")
    XCTAssertTrue(AssistantPreset.pageSelection.isAvailable(player: player, channel: channel))
    XCTAssertFalse(AssistantPreset.translateLine.isAvailable(player: player, channel: channel))
    XCTAssertFalse(AssistantPreset.recap.isAvailable(player: player, channel: channel))
  }
}

final class AssistantResearchConfigurationTests: XCTestCase {
  func testNativeClaudeProviderDoesNotInheritDeepSeekSearch() {
    let configuration = AssistantConfiguration(
      provider: .claude,
      profileID: "deepseek",
      endpoint: "https://api.anthropic.com/v1/messages",
      model: "claude-sonnet-5-5",
      apiKey: "test")
    XCTAssertFalse(configuration.isDeepSeek)
    XCTAssertFalse(configuration.supportsResearch)
    XCTAssertNil(configuration.deepSeekSearchURL)
  }

  func testDeepSeekProfileWithAnotherEndpointDisablesResearch() {
    let configuration = AssistantConfiguration(
      provider: .openAICompatible,
      profileID: "deepseek",
      endpoint: "https://example.com/v1",
      model: "test",
      apiKey: "test")
    XCTAssertFalse(configuration.isDeepSeek)
    XCTAssertFalse(configuration.supportsResearch)
    XCTAssertNil(configuration.deepSeekSearchURL)
  }

  func testInsecureOrNonstandardDeepSeekOriginsDisableResearch() {
    for endpoint in ["http://api.deepseek.com", "https://api.deepseek.com:8443"] {
      let configuration = AssistantConfiguration(
        provider: .openAICompatible,
        profileID: "deepseek",
        endpoint: endpoint,
        model: "test",
        apiKey: "test")
      XCTAssertFalse(configuration.isDeepSeek, endpoint)
      XCTAssertFalse(configuration.supportsResearch, endpoint)
    }
  }
}

@MainActor
final class AssistantCompanionViewModelTests: XCTestCase {
  private final class Executor: AssistantToolExecuting {
    func seek(to seconds: Double) -> Bool { false }
    func currentSubtitle() -> String? { "A line" }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "range" }
  }

  private final class SeekingExecutor: AssistantToolExecuting {
    var sought: Double?
    func seek(to seconds: Double) -> Bool { sought = seconds; return true }
    func currentSubtitle() -> String? { nil }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "range" }
  }

  private final class SequenceResearch: AssistantResearchProviding {
    var results: [Result<AssistantResearchResult, Error>]

    init(_ results: [Result<AssistantResearchResult, Error>]) {
      self.results = results
    }

    func search(query: String, count: Int) async throws -> AssistantResearchResult {
      guard !results.isEmpty else { throw AssistantResearchError.offline }
      return try results.removeFirst().get()
    }
  }

  private final class DeferredResearch: AssistantResearchProviding {
    private var continuation: CheckedContinuation<AssistantResearchResult, Error>?
    private(set) var started = false

    func search(query: String, count: Int) async throws -> AssistantResearchResult {
      started = true
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
      }
    }

    func finish(_ result: AssistantResearchResult) {
      continuation?.resume(returning: result)
      continuation = nil
    }
  }

  private final class StubResearch: AssistantResearchProviding {
    var queries: [String] = []
    let result: AssistantResearchResult

    init(result: AssistantResearchResult) { self.result = result }

    func search(query: String, count: Int) async throws -> AssistantResearchResult {
      queries.append(query)
      return result
    }
  }

  private final class FailingProvider: AssistantProvider {
    let identifier = "failing-companion"
    func stream(_ request: AssistantRequest, configuration: AssistantConfiguration)
      -> AsyncThrowingStream<AssistantStreamEvent, Error> {
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: AssistantError.offline)
      }
    }
  }

  private final class BlockingResearch: AssistantResearchProviding {
    func search(query: String, count: Int) async throws -> AssistantResearchResult {
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return AssistantResearchResult(query: query, sources: [])
    }
  }

  private final class CaptureProvider: AssistantProvider {
    let identifier = "capture-companion"
    var requests: [AssistantRequest] = []

    func stream(_ request: AssistantRequest,
                configuration: AssistantConfiguration)
      -> AsyncThrowingStream<AssistantStreamEvent, Error> {
      requests.append(request)
      return AsyncThrowingStream { continuation in
        continuation.yield(.text("Answer"))
        continuation.finish()
      }
    }
  }

  private let configuration = AssistantConfiguration(
    provider: .openAICompatible,
    profileID: "deepseek",
    endpoint: "https://api.deepseek.com",
    model: "deepseek-flash",
    apiKey: "test-key")

  private let researchSource = AssistantResearchSource(
    title: "A review",
    url: URL(string: "https://example.com/review")!,
    siteName: "Example",
    date: "2026-06-01T00:00:00+00:00",
    snippet: "Snippet",
    summary: "Summary",
    authority: 3,
    rerankScore: 2.4)

  private func context() -> PlaybackContext {
    PlaybackContextBuilder.make(
      snapshot: PlayerSnapshot(
        title: "Example.Show.S02E03.1080p.mkv",
        url: URL(fileURLWithPath: "/tmp/Example.Show.S02E03.1080p.mkv"),
        isNetwork: false, position: 125, duration: 600, speed: 1,
        audioTrack: "English", subtitleTrack: "English",
        subtitleLine: "Who is that?",
        metadata: LibraryMetadata(
          title: "Example Show", year: 2024, season: 2, episode: 3, quality: "1080p"),
        recentDialogue: [DialogueLine(position: 120, text: "Who is that?")]),
      options: .init())
  }

  private func waitUntil(timeout: TimeInterval = 2,
                         _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func testReviewsPresetAttachesResearchAndSources() async {
    let research = StubResearch(
      result: AssistantResearchResult(query: "q", sources: [researchSource]))
    let provider = CaptureProvider()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "movie" }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil {
      model.research != nil && !model.isResearching && !model.isStreaming
        && model.transcript.contains { $0.kind == .user }
    }

    XCTAssertEqual(model.research?.sourceCount, 1)
    XCTAssertEqual(research.queries.count, 1)
    XCTAssertTrue(research.queries.first?.contains("site:reddit.com") == true)
    XCTAssertTrue(model.contextDisclosure?.contains("https://example.com/review") == true)
    XCTAssertTrue(model.transcript.contains { $0.text == "Found 1 sources." })
    XCTAssertTrue(provider.requests.last?.messages.contains {
      $0.content.contains("Web search results")
    } == true)
    XCTAssertTrue(model.transcript.contains {
      $0.kind == .user && $0.text.contains("Avoid spoilers")
    })
  }

  func testSearchWebToolExecutesThroughTheResearchProvider() async {
    let research = StubResearch(
      result: AssistantResearchResult(query: "q", sources: [researchSource]))
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let provider = ScriptedAssistantProvider([
      [.toolCalls([call])],
      [.text("Done")],
    ])
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    model.refreshContext()

    model.send("search")
    await waitUntil { model.pendingTool != nil }
    XCTAssertEqual(model.pendingTool?.arguments, .searchWeb(query: "Example Show reviews"))
    model.confirmPendingTool()
    await waitUntil {
      !model.isStreaming && model.research != nil
        && model.transcript.contains { $0.text == "Done" }
    }

    XCTAssertEqual(research.queries, ["Example Show reviews"])
    XCTAssertEqual(model.research?.sourceCount, 1)
    XCTAssertTrue(model.transcript.contains {
      $0.kind == .notice && $0.text.contains("searchWeb")
    })
  }

  func testPresetResearchIsDiscardedWhenPlaybackChanges() async {
    let research = DeferredResearch()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in CaptureProvider() },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    var mediaID = "A"
    model.currentMediaID = { mediaID }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil { model.isResearching && research.started }
    mediaID = "B"
    research.finish(AssistantResearchResult(query: "q", sources: [researchSource]))
    await waitUntil { !model.isResearching }

    XCTAssertNil(model.research)
    XCTAssertFalse(model.transcript.contains { $0.kind == .user })
    XCTAssertTrue(model.transcript.contains {
      $0.text == "Playback changed before the search finished."
    })
  }

  func testToolExecutionBlocksSendAndClearCancelsLateSearch() async {
    let research = DeferredResearch()
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let provider = ScriptedAssistantProvider([[.toolCalls([call])], [.text("Done")]])
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    model.currentMediaID = { "A" }
    model.refreshContext()

    model.send("search")
    await waitUntil { model.pendingTool != nil }
    model.confirmPendingTool()
    await waitUntil { model.isExecutingTool && research.started }

    model.send("second")
    XCTAssertFalse(model.transcript.contains {
      $0.kind == .user && $0.text == "second"
    })

    model.clear()
    XCTAssertFalse(model.isExecutingTool)
    XCTAssertTrue(model.transcript.isEmpty)
    research.finish(AssistantResearchResult(query: "q", sources: [researchSource]))
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(model.research)
  }

  func testToolBatchStopsWhenPlaybackChangesDuringSearch() async {
    let research = DeferredResearch()
    let search = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let seek = AssistantToolCall(
      id: "2", name: "seek", argumentsJSON: #"{"seconds": 30}"#)
    let provider = ScriptedAssistantProvider([
      [.toolCalls([search, seek])],
      [.text("Done")],
    ])
    let executor = SeekingExecutor()
    let model = AssistantViewModel(
      toolExecutor: executor,
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    var mediaID = "A"
    model.currentMediaID = { mediaID }
    model.refreshContext()

    model.send("search then seek")
    await waitUntil { model.pendingTool != nil }
    model.confirmPendingTool()
    await waitUntil { model.isExecutingTool && research.started }
    mediaID = "B"
    research.finish(AssistantResearchResult(query: "q", sources: [researchSource]))
    await waitUntil { !model.isExecutingTool && !model.isStreaming }

    XCTAssertNil(executor.sought)
    XCTAssertNil(model.research)
    XCTAssertTrue(model.transcript.contains {
      $0.text == "Playback changed; the remaining tool calls were cancelled."
    })
  }

  func testPresetResearchIsDiscardedWhenChannelContextChanges() async {
    let research = DeferredResearch()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in CaptureProvider() },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "A" }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil { model.isResearching && research.started }
    model.setChannelContext(ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote"))
    research.finish(AssistantResearchResult(query: "q", sources: [researchSource]))
    await waitUntil { !model.isResearching }

    XCTAssertNil(model.research)
    XCTAssertFalse(model.transcript.contains { $0.kind == .user })
    XCTAssertTrue(model.transcript.contains {
      $0.text == "Context changed before the search finished."
    })
  }

  func testResearchWithoutMediaExpiresWhenMediaOpens() async {
    let research = StubResearch(
      result: AssistantResearchResult(query: "q", sources: [researchSource]))
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let provider = ScriptedAssistantProvider([[.toolCalls([call])], [.text("Done")]])
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    var mediaID: String?
    model.currentMediaID = { mediaID }
    model.refreshContext()

    model.send("search")
    await waitUntil { model.pendingTool != nil }
    model.confirmPendingTool()
    await waitUntil { !model.isExecutingTool && !model.isStreaming && model.research != nil }
    XCTAssertNotNil(model.research)

    mediaID = "A"
    model.refreshContext()

    XCTAssertNil(model.research)
  }

  func testRetryIsDisabledWhilePresetResearchRuns() async {
    let research = DeferredResearch()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in FailingProvider() },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "A" }
    model.refreshContext()

    model.send("fail once")
    await waitUntil { model.errorMessage != nil }
    XCTAssertTrue(model.canRetry)

    model.sendPreset(.reviews)
    await waitUntil { model.isResearching && research.started }
    XCTAssertFalse(model.canRetry)
    model.stop()
    research.finish(AssistantResearchResult(query: "q", sources: []))
    try? await Task.sleep(nanoseconds: 50_000_000)
  }

  func testResearchRefreshUpdatesContextAndFailureClearsOldSources() async {
    let research = SequenceResearch([
      .success(AssistantResearchResult(query: "q", sources: [researchSource])),
      .failure(AssistantResearchError.offline),
    ])
    let provider = CaptureProvider()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "movie" }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil {
      model.research != nil && !model.isResearching && !model.isStreaming
    }
    XCTAssertTrue(provider.requests.last?.messages.contains {
      $0.content.contains("https://example.com/review")
    } == true)

    model.sendPreset(.reviews)
    await waitUntil {
      !model.isResearching && model.research == nil
        && model.transcript.contains { $0.text.contains("Web research failed") }
    }
    model.send("follow up")
    await waitUntil { !model.isStreaming }

    XCTAssertTrue(provider.requests.last?.messages.contains {
      $0.content.contains("Context:") && $0.content.contains("https://example.com/review")
    } == false)
  }

  func testChannelChangeInvalidatesCompletedResearch() async {
    let research = StubResearch(
      result: AssistantResearchResult(query: "q", sources: [researchSource]))
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in CaptureProvider() },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "movie" }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil { model.research != nil && !model.isResearching }

    model.setChannelContext(ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote"))

    XCTAssertNil(model.research)
  }

  func testConfirmationIsDiscardedWhenChannelChangesBeforeAllow() async {
    let research = StubResearch(
      result: AssistantResearchResult(query: "q", sources: [researchSource]))
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let provider = ScriptedAssistantProvider([[.toolCalls([call])], [.text("Done")]])
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    model.currentMediaID = { "A" }
    model.refreshContext()

    model.send("search")
    await waitUntil { model.pendingTool != nil }
    model.setChannelContext(ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote"))
    model.confirmPendingTool()

    XCTAssertNil(model.research)
    XCTAssertTrue(model.transcript.contains {
      $0.text == "Playback changed before confirmation; the request was discarded."
    })
  }

  func testToolSearchIsDiscardedWhenChannelContextChanges() async {
    let research = DeferredResearch()
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"Example Show reviews"}"#)
    let provider = ScriptedAssistantProvider([[.toolCalls([call])], [.text("Done")]])
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in provider },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    model.currentMediaID = { "A" }
    model.refreshContext()

    model.send("search")
    await waitUntil { model.pendingTool != nil }
    model.confirmPendingTool()
    await waitUntil { model.isExecutingTool && research.started }
    model.setChannelContext(ChannelPageContext(
      title: "A page", url: URL(string: "https://example.com")!, selection: "A quote"))
    research.finish(AssistantResearchResult(query: "q", sources: [researchSource]))
    await waitUntil { !model.isExecutingTool && !model.isStreaming }

    XCTAssertNil(model.research)
    XCTAssertTrue(model.transcript.contains {
      $0.text == "Context changed; the remaining tool calls were cancelled."
    })
  }

  func testStopCancelsResearchAndResolvesTheNotice() async {
    let research = BlockingResearch()
    let model = AssistantViewModel(
      toolExecutor: Executor(),
      service: AssistantService { _ in CaptureProvider() },
      configurationProvider: { [configuration] in configuration },
      researchProvider: { _ in research })
    let playbackContext = context()
    model.playerContextProvider = { _ in playbackContext }
    model.currentMediaID = { "movie" }
    model.refreshContext()

    model.sendPreset(.reviews)
    await waitUntil { model.isResearching }

    model.stop()

    XCTAssertFalse(model.isResearching)
    XCTAssertTrue(model.transcript.contains { $0.text == "Search stopped." })
    XCTAssertNil(model.research)
  }

  func testSearchWebRequiresConfirmation() throws {
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"A review"}"#)
    let typed = try AssistantToolParser.parse(call)
    XCTAssertTrue(typed.requiresConfirmation)
  }

  func testSearchWebParsingRejectsOverlongQueries() {
    let call = AssistantToolCall(
      id: "1", name: "searchWeb",
      argumentsJSON: #"{"query":"\#(String(repeating: "x", count: 129))"}"#)
    XCTAssertThrowsError(try AssistantToolParser.parse(call))
  }
}

private final class ResearchURLProtocol: URLProtocol {
  static var status = 200
  static var payload = Data()
  static var redirectURL: URL?
  static var didRedirect = false
  static var capturedURL: URL?
  static var capturedBody: Data?
  static var capturedAuthorization: String?

  static func reset() {
    status = 200
    payload = Data()
    redirectURL = nil
    didRedirect = false
    capturedURL = nil
    capturedBody = nil
    capturedAuthorization = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.capturedURL = request.url
    Self.capturedBody = Self.bodyData(request)
    Self.capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
    if let redirectURL = Self.redirectURL, !Self.didRedirect {
      Self.didRedirect = true
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectURL.absoluteString])!
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: redirectURL),
        redirectResponse: response)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.payload)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func bodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
