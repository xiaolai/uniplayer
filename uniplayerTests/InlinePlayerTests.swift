//
//  InlinePlayerTests.swift
//  UniPlayerTests
//

import AppKit
import XCTest
@testable import UniPlayer

final class PresentationStateTests: XCTestCase {

  func testStartsInWindow() {
    XCTAssertEqual(PlayerPresentationState().current, .window)
  }

  func testWindowToInlineAndBack() throws {
    var state = PlayerPresentationState()
    XCTAssertTrue(try state.transition(to: .inline))
    XCTAssertEqual(state.current, .inline)
    XCTAssertTrue(try state.transition(to: .window))
    XCTAssertEqual(state.current, .window)
  }

  func testRepeatedTransitionIsNoChange() throws {
    var state = PlayerPresentationState()
    XCTAssertFalse(try state.transition(to: .window))
  }

  func testWindowRoundTripsThroughMiniPlayer() throws {
    var state = PlayerPresentationState()
    XCTAssertTrue(try state.transition(to: .miniPlayer))
    XCTAssertTrue(try state.transition(to: .window))
  }

  func testInlineAndMiniPlayerNeverHandOffDirectly() throws {
    var state = PlayerPresentationState()
    XCTAssertTrue(try state.transition(to: .inline))
    XCTAssertThrowsError(try state.transition(to: .miniPlayer)) { error in
      XCTAssertEqual(error as? PlayerPresentationState.TransitionError, .directInlineToMiniPlayer)
    }
    XCTAssertEqual(state.current, .inline)

    state = PlayerPresentationState()
    XCTAssertTrue(try state.transition(to: .miniPlayer))
    XCTAssertThrowsError(try state.transition(to: .inline)) { error in
      XCTAssertEqual(error as? PlayerPresentationState.TransitionError, .directMiniPlayerToInline)
    }
    XCTAssertEqual(state.current, .miniPlayer)
  }
}

final class PlayerSurfaceMoverTests: XCTestCase {

  func testAttachPinsSurfaceAndIsIdempotent() {
    let surface = NSView()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let mover = PlayerSurfaceMover(surface: surface)

    XCTAssertTrue(mover.attach(to: container))
    XCTAssertTrue(surface.superview === container)
    container.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.frame, container.bounds)

    XCTAssertFalse(mover.attach(to: container))
    XCTAssertEqual(container.subviews.count, 1)
  }

  func testRestoreMovesSurfaceAndActivatesConstraints() {
    let surface = NSView()
    let inline = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let window = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let mover = PlayerSurfaceMover(surface: surface)

    mover.attach(to: inline)
    let constraints = [
      surface.leadingAnchor.constraint(equalTo: window.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: window.trailingAnchor),
      surface.topAnchor.constraint(equalTo: window.topAnchor),
      surface.bottomAnchor.constraint(equalTo: window.bottomAnchor),
    ]
    mover.restore(to: window, constraints: constraints)
    window.layoutSubtreeIfNeeded()

    XCTAssertTrue(surface.superview === window)
    XCTAssertTrue(inline.subviews.isEmpty)
    XCTAssertEqual(surface.frame, window.bounds)
  }
}

final class PlaybackContextTests: XCTestCase {

  private func snapshot(url: URL, isNetwork: Bool = false) -> PlayerSnapshot {
    PlayerSnapshot(
      title: url.lastPathComponent,
      url: url,
      isNetwork: isNetwork,
      position: 125,
      duration: 600,
      speed: 1.25,
      audioTrack: "English",
      subtitleTrack: "English",
      subtitleLine: "  Hello there.  ")
  }

  func testLocalPathIsRedactedToFileName() {
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot(url: URL(fileURLWithPath: "/Users/example/Private/Movie.mkv")),
      options: .init())
    XCTAssertEqual(context.source, "Movie.mkv")
    XCTAssertNil(context.filePath)
    XCTAssertFalse(context.disclosure.contains("/Users/example/Private"))
  }

  func testFullPathRequiresOptIn() {
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot(url: URL(fileURLWithPath: "/Users/example/Private/Movie.mkv")),
      options: .init(includeFilePath: true))
    XCTAssertEqual(context.filePath, "/Users/example/Private/Movie.mkv")
    XCTAssertTrue(context.disclosure.contains("/Users/example/Private/Movie.mkv"))
  }

  func testNetworkSourceDropsQueryAndFragment() {
    let url = URL(string: "https://example.com/watch/1?token=secret#frag")!
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot(url: url, isNetwork: true), options: .init())
    XCTAssertEqual(context.source, "example.com/watch/1")
    XCTAssertFalse(context.disclosure.contains("secret"))
  }

  func testDisclosureIncludesTimeAndTrimmedSubtitle() {
    let context = PlaybackContextBuilder.make(
      snapshot: snapshot(url: URL(fileURLWithPath: "/tmp/Movie.mkv")),
      options: .init())
    XCTAssertEqual(context.timestamp, "02:05")
    XCTAssertEqual(context.subtitleLine, "Hello there.")
    XCTAssertTrue(context.disclosure.contains("Position: 02:05 of 10:00"))
  }

  func testChannelContextDisclosure() {
    let context = ChannelPageContext(
      title: "Test Video", url: URL(string: "https://example.com/v/1?x=1")!,
      selection: "A quote")
    XCTAssertEqual(context.source, "example.com/v/1")
    XCTAssertTrue(context.disclosure.contains("A quote"))
  }
}

final class AssistantToolTests: XCTestCase {

  private final class StubExecutor: AssistantToolExecuting {
    var sought: Double?
    @discardableResult
    func seek(to seconds: Double) -> Bool { sought = seconds; return true }
    func currentSubtitle() -> String? { "Hello" }
    func relatedItems(matching query: String) -> [String] { ["Alpha", "Beta"] }
    func rangeDescription(start: Double, end: Double) -> String { "range \(start)-\(end)" }
  }

  func testSeekRequiresConfirmation() throws {
    let call = AssistantToolCall(id: "1", name: "seek", argumentsJSON: #"{"seconds": 30, "reason": "skip intro"}"#)
    let typed = try AssistantToolParser.parse(call)
    XCTAssertTrue(typed.requiresConfirmation)
    XCTAssertEqual(typed.arguments, .seek(seconds: 30, reason: "skip intro"))
  }

  func testUnknownToolIsRejected() {
    let call = AssistantToolCall(id: "1", name: "quitApp", argumentsJSON: "{}")
    XCTAssertThrowsError(try AssistantToolParser.parse(call)) { error in
      XCTAssertEqual(error as? AssistantToolError, .unknownTool("quitApp"))
    }
  }

  func testMalformedArgumentsAreRejected() {
    let call = AssistantToolCall(id: "1", name: "seek", argumentsJSON: "not json")
    XCTAssertThrowsError(try AssistantToolParser.parse(call)) { error in
      guard case .invalidArguments = error as? AssistantToolError else {
        return XCTFail("expected invalidArguments, got \(error)")
      }
    }
  }

  func testBooleanStringAndUnboundedNumbersAreRejected() {
    for arguments in [#"{"seconds": true}"#, #"{"seconds": "30"}"#,
                      #"{"seconds": 1e20}"#, #"{"seconds": -1}"#] {
      let call = AssistantToolCall(id: "1", name: "seek", argumentsJSON: arguments)
      XCTAssertThrowsError(try AssistantToolParser.parse(call), arguments)
    }
  }

  func testSummarizeRangeValidatesOrder() {
    let call = AssistantToolCall(id: "1", name: "summarizeRange", argumentsJSON: #"{"start": 10, "end": 5}"#)
    XCTAssertThrowsError(try AssistantToolParser.parse(call))
  }

  func testToolExecutionUsesNarrowCapabilities() throws {
    let executor = StubExecutor()
    let seek = try AssistantToolParser.parse(
      AssistantToolCall(id: "1", name: "seek", argumentsJSON: #"{"seconds": 42}"#))
    _ = AssistantToolExecutor.execute(seek, executor: executor)
    XCTAssertEqual(executor.sought, 42)

    let related = try AssistantToolParser.parse(
      AssistantToolCall(id: "2", name: "findRelatedItems", argumentsJSON: #"{"query": "alpha"}"#))
    XCTAssertEqual(AssistantToolExecutor.execute(related, executor: executor), "Alpha\nBeta")
  }
}

final class StreamingURLProtocol: URLProtocol {
  static var statusCode = 200
  static var body = Data()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class AssistantProviderTests: XCTestCase {

  private func providerSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private var configuration: AssistantConfiguration {
    AssistantConfiguration(
      provider: .openAICompatible,
      endpoint: "http://localhost/v1/chat/completions",
      model: "test",
      apiKey: "test-key")
  }

  private var request: AssistantRequest {
    AssistantRequest(
      messages: [AssistantProviderMessage(role: .user, content: "hi")],
      tools: [])
  }

  func testOpenAIStreamsTextDeltas() async throws {
    StreamingURLProtocol.statusCode = 200
    StreamingURLProtocol.body = Data("""
    data: {"choices":[{"delta":{"content":"Hello"}}]}

    data: {"choices":[{"delta":{"content":" world"}}]}

    data: [DONE]


    """.utf8)

    let provider = OpenAICompatibleProvider(session: providerSession())
    var events: [AssistantStreamEvent] = []
    for try await event in provider.stream(request, configuration: configuration) {
      events.append(event)
    }
    XCTAssertEqual(events, [.text("Hello"), .text(" world")])
  }

  func testUnauthorizedResponseThrows() async {
    StreamingURLProtocol.statusCode = 401
    StreamingURLProtocol.body = Data()
    let provider = OpenAICompatibleProvider(session: providerSession())
    do {
      for try await _ in provider.stream(request, configuration: configuration) {}
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? AssistantError, .unauthorized)
    }
  }

  func testMissingKeyFailsBeforeNetworking() async {
    var withoutKey = configuration
    withoutKey.endpoint = "https://example.com/v1/chat/completions"
    withoutKey.apiKey = nil
    let provider = OpenAICompatibleProvider(session: providerSession())
    do {
      for try await _ in provider.stream(request, configuration: withoutKey) {}
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? AssistantError, .missingAPIKey)
    }
  }

  func testNetworkErrorsMapToOffline() {
    XCTAssertEqual(
      OpenAICompatibleProvider.map(URLError(.cannotConnectToHost)), .offline)
    XCTAssertEqual(
      OpenAICompatibleProvider.map(URLError(.timedOut)), .timedOut)
    XCTAssertEqual(
      OpenAICompatibleProvider.map(CancellationError()), .cancelled)
  }

  func testMockProviderEmitsConfiguredEvents() async throws {
    let provider = MockAssistantProvider()
    var events: [AssistantStreamEvent] = []
    for try await event in provider.stream(request, configuration: configuration) {
      events.append(event)
    }
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first, .text("This is a mock answer. "))
  }
}

/// A provider that returns one scripted round per request, so a tool loop can
/// be tested without repeating itself forever.
final class ScriptedAssistantProvider: AssistantProvider {
  let identifier = "scripted"
  private var rounds: [[AssistantStreamEvent]]

  init(_ rounds: [[AssistantStreamEvent]]) {
    self.rounds = rounds
  }

  func stream(_ request: AssistantRequest,
              configuration: AssistantConfiguration) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    let events = rounds.isEmpty ? [] : rounds.removeFirst()
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

@MainActor
final class AssistantViewModelTests: XCTestCase {

  private final class StubExecutor: AssistantToolExecuting {
    var sought: Double?
    @discardableResult
    func seek(to seconds: Double) -> Bool { sought = seconds; return true }
    func currentSubtitle() -> String? { "Hello" }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "range" }
  }

  private let configuration = AssistantConfiguration(
    provider: .openAICompatible,
    endpoint: "http://localhost/v1/chat/completions",
    model: "test",
    apiKey: "test")

  private func makeModel(_ rounds: [[AssistantStreamEvent]],
                         executor: StubExecutor) -> AssistantViewModel {
    let provider = ScriptedAssistantProvider(rounds)
    let service = AssistantService { _ in provider }
    return AssistantViewModel(
      toolExecutor: executor,
      service: service,
      configurationProvider: { [configuration] in configuration })
  }

  private func waitUntil(timeout: TimeInterval = 2,
                         _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func testStreamingTextIsAppendedAndFinished() async {
    let executor = StubExecutor()
    let model = makeModel([[.text("He"), .text("llo")]], executor: executor)
    model.send("hi")
    await waitUntil { !model.isStreaming }
    XCTAssertEqual(model.transcript.last?.text, "Hello")
    XCTAssertEqual(model.transcript.last?.kind, .assistant)
    XCTAssertFalse(model.transcript.last?.isPartial ?? true)
  }

  func testSeekToolRequiresConfirmationBeforeMoving() async {
    let executor = StubExecutor()
    let call = AssistantToolCall(
      id: "1", name: "seek", argumentsJSON: #"{"seconds": 12}"#)
    let model = makeModel(
      [[.text("Seeking."), .toolCalls([call])], [.text("Done.")]],
      executor: executor)

    model.send("go to 12 seconds")
    await waitUntil { model.pendingTool != nil }
    XCTAssertNotNil(model.pendingTool)
    XCTAssertNil(executor.sought)

    model.confirmPendingTool()
    await waitUntil { model.transcript.last?.text == "Done." }
    XCTAssertEqual(executor.sought, 12)
    XCTAssertNil(model.pendingTool)
  }

  func testCancellingConfirmationDoesNotSeek() async {
    let executor = StubExecutor()
    let call = AssistantToolCall(
      id: "1", name: "seek", argumentsJSON: #"{"seconds": 12}"#)
    let model = makeModel([[.toolCalls([call])]], executor: executor)

    model.send("seek")
    await waitUntil { model.pendingTool != nil }
    model.cancelPendingTool()
    XCTAssertNil(executor.sought)
    XCTAssertNil(model.pendingTool)
  }

  func testUnknownToolIsRejectedWithoutExecuting() async {
    let executor = StubExecutor()
    let call = AssistantToolCall(id: "1", name: "quitApp", argumentsJSON: "{}")
    let model = makeModel([[.toolCalls([call])]], executor: executor)

    model.send("do something else")
    await waitUntil { !model.isStreaming }
    let notices = model.transcript.filter { $0.kind == .notice }.map(\.text)
    XCTAssertTrue(notices.contains { $0.contains("unknown tool") })
    XCTAssertNil(executor.sought)
  }

  func testNotConfiguredShowsClearError() async {
    let executor = StubExecutor()
    let provider = ScriptedAssistantProvider([[.text("unused")]])
    let service = AssistantService { _ in provider }
    var empty = configuration
    empty.endpoint = "https://example.com/v1/chat/completions"
    empty.apiKey = nil
    let model = AssistantViewModel(
      toolExecutor: executor,
      service: service,
      configurationProvider: { empty })

    model.send("hello")
    await waitUntil { model.errorMessage != nil }
    XCTAssertEqual(model.errorMessage, AssistantError.notConfigured.errorDescription)
  }
}

final class AssistantStreamingTests: XCTestCase {

  func testSSEParserEmitsEachDataPayload() {
    var parser = SSEParser()
    XCTAssertEqual(parser.consume(line: "data: one"), .data("one"))
    XCTAssertNil(parser.consume(line: ""))
    XCTAssertEqual(parser.consume(line: "data: [DONE]"), .done)
  }

  func testOpenAIToolFragmentsAccumulate() {
    var accumulator = ToolCallAccumulator()
    accumulator.openAIDelta([
      "tool_calls": [[
        "index": 0,
        "id": "call_1",
        "function": ["name": "seek", "arguments": #"{"sec"#],
      ]],
    ])
    accumulator.openAIDelta([
      "tool_calls": [[
        "index": 0,
        "function": ["arguments": #"onds": 5}"#],
      ]],
    ])
    XCTAssertEqual(
      accumulator.finalize(),
      [AssistantToolCall(id: "call_1", name: "seek", argumentsJSON: #"{"seconds": 5}"#)])
  }

  func testConfigurationRequiresModelURLAndKey() {
    let valid = AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://127.0.0.1:11434/v1/chat/completions",
      model: "local", apiKey: "x")
    XCTAssertTrue(valid.isConfigured)

    XCTAssertFalse(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://127.0.0.1:11434/v1/chat/completions",
      model: "", apiKey: "x").isConfigured)
    XCTAssertFalse(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "file:///etc/passwd",
      model: "local", apiKey: "x").isConfigured)
    XCTAssertFalse(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "https://example.com/v1",
      model: "local", apiKey: nil).isConfigured)
    // Local providers accept unauthenticated requests.
    XCTAssertTrue(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://127.0.0.1:11434/v1/chat/completions",
      model: "local", apiKey: nil).isConfigured)
    // Private literals are LAN services; a hostname that merely starts with
    // the same digits is public and needs a key.
    XCTAssertFalse(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://10.0.0.5:11434/v1",
      model: "local", apiKey: nil).requiresAPIKey)
    XCTAssertTrue(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://10.attacker.example/v1",
      model: "local", apiKey: nil).requiresAPIKey)
    // HTTPS is never assumed to be unauthenticated.
    XCTAssertTrue(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "https://127.0.0.1/v1",
      model: "local", apiKey: nil).requiresAPIKey)
    // All of 127/8 is loopback; an invalid IPv4 literal is public.
    XCTAssertFalse(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://127.0.0.2/v1",
      model: "local", apiKey: nil).requiresAPIKey)
    XCTAssertTrue(AssistantConfiguration(
      provider: .openAICompatible, endpoint: "http://10.1.2.999/v1",
      model: "local", apiKey: nil).requiresAPIKey)
  }

  func testPathRedactionCoversJSONEscapes() {
    let path = "/Users/example/Pr\\ivate\"movie\"/film.mp4"
    let raw = "path: \(path)"
    XCTAssertEqual(AssistantRedaction.scrub(raw, path: path, replacement: "film.mp4"),
                   "path: film.mp4")

    let json = #"{"path":"\/Users\/example\/Pr\\ivate\"movie\"\/film.mp4"}"#
    let scrubbed = AssistantRedaction.scrub(json, path: path, replacement: "film.mp4")
    XCTAssertFalse(scrubbed.contains("Users"))
    XCTAssertTrue(scrubbed.contains("film.mp4"))
  }
}

