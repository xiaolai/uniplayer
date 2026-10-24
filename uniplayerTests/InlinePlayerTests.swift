//
//  InlinePlayerTests.swift
//  UniPlayerTests
//

import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
@testable import UniPlayer

@MainActor
final class PlayerHUDLayoutTests: XCTestCase {
  private func makePlayerWindow() -> (MainWindow, PlayerHUDView, NSView) {
    let window = MainWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1220, height: 610),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.configureFloatingPlayerTitlebar(windowed: true)
    let hud = PlayerHUDView()
    window.contentView!.addSubview(hud)
    hud.padding(.all)
    for (stack, height) in [(hud.topLeading, 24.0), (hud.topTrailing, 20.0)] {
      let button = NSButton(title: "Control", target: nil, action: nil)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.size(width: 80, height: height)
      stack.addArrangedSubview(HUDCapsuleView(content: button))
    }
    let timelineContent = NSView()
    timelineContent.translatesAutoresizingMaskIntoConstraints = false
    timelineContent.heightAnchor.constraint(equalToConstant: 20).isActive = true
    hud.installTimelineContent(timelineContent)
    return (window, hud, timelineContent)
  }

  private func settle(_ window: NSWindow, hud: PlayerHUDView) {
    // Native titlebar layout and the HUD's measured alignment need to settle.
    for _ in 0..<3 {
      window.contentView!.superview!.layoutSubtreeIfNeeded()
      hud.needsLayout = true
      hud.layoutSubtreeIfNeeded()
    }
  }

  func testWindowedControlsShareNativeButtonCenterAndTimelineIsCentered() {
    let (window, hud, timelineContent) = makePlayerWindow()
    defer { window.close() }
    for size in [NSSize(width: 1220, height: 610), NSSize(width: 640, height: 360),
                 NSSize(width: 900, height: 700)] {
      window.setContentSize(size)
      settle(window, hud: hud)
      let close = window.standardWindowButton(.closeButton)!
      let native = hud.convert(close.bounds, from: close)
      XCTAssertEqual(hud.topLeading.frame.midY, native.midY, accuracy: 0.5)
      XCTAssertEqual(hud.topTrailing.frame.midY, native.midY, accuracy: 0.5)
      XCTAssertEqual(timelineContent.frame.midY, hud.timeline.bounds.midY, accuracy: 0.5)
      XCTAssertEqual(hud.frame, window.contentView!.bounds, "Video/HUD must retain full window height")
      XCTAssertEqual(window.toolbarStyle, .unified)
      XCTAssertTrue(window.titlebarAppearsTransparent)
      XCTAssertGreaterThan(native.minX, 9, "Use the native toolbar inset, not the plain titlebar inset")
      let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
        .map { hud.convert($0.bounds, from: $0) }
        .reduce(CGRect.null) { $0.union($1) }
      XCTAssertEqual(hud.topLeading.frame.minX - buttons.maxX,
                     buttons.minX - hud.bounds.minX, accuracy: 0.5,
                     "Traffic lights need equal space before and after the group")
    }
  }

  func testFullscreenLayoutAndReturnRestoreNativeAlignment() {
    let (window, hud, _) = makePlayerWindow()
    defer { window.close() }
    window.configureFloatingPlayerTitlebar(windowed: false)
    hud.updateForFullScreen(true)
    settle(window, hud: hud)
    XCTAssertNil(window.toolbar)
    XCTAssertEqual(hud.bounds.maxY - hud.topLeading.frame.maxY, Tokens.HUD.topMargin, accuracy: 0.5)
    XCTAssertEqual(hud.topLeading.frame.midY, hud.topTrailing.frame.midY, accuracy: 0.5)
    window.configureFloatingPlayerTitlebar(windowed: true)
    hud.updateForFullScreen(false)
    settle(window, hud: hud)
    let close = window.standardWindowButton(.closeButton)!
    XCTAssertEqual(hud.topLeading.frame.midY, hud.convert(close.bounds, from: close).midY, accuracy: 0.5)
  }
}

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


final class LibraryRemediationTests: XCTestCase {
  private func item(_ name: String, progress: Double = 0, missing: Bool = false) -> UniPlayer.LibraryItem {
    UniPlayer.LibraryItem(url: URL(fileURLWithPath: "/tmp/\(name).mp4"), title: name,
                subtitle: "Fixtures", metadata: .parse(fileName: name), duration: 100,
                progress: progress, added: Date(), isNetwork: false, isMissing: missing)
  }

  func testVideoHeightStaysInsideShortAndWideViewports() {
    XCTAssertLessThanOrEqual(LibraryLayout.videoHeight(width: 1400, viewportHeight: 560), 320)
    XCTAssertLessThanOrEqual(LibraryLayout.videoHeight(width: 300, viewportHeight: 560), 169)
    XCTAssertGreaterThan(LibraryLayout.videoHeight(width: 900, viewportHeight: 720), 200)
  }

  func testPanesExpandOutwardsAndCloseReversibly() {
    let frame = NSRect(x: 500, y: 100, width: 800, height: 600)
    let screen = NSRect(x: 0, y: 0, width: 2200, height: 1000)
    let left = LibraryLayout.paneFrame(frame: frame, screen: screen, delta: 280, left: true)
    XCTAssertEqual(left, NSRect(x: 220, y: 100, width: 1080, height: 600))
    XCTAssertEqual(LibraryLayout.paneFrame(frame: left!, screen: screen, delta: -280, left: true), frame)
    let right = LibraryLayout.paneFrame(frame: frame, screen: screen, delta: 360, left: false)
    XCTAssertEqual(right, NSRect(x: 500, y: 100, width: 1160, height: 600))
  }

  func testPaneExpansionRepositionsAtScreenEdgeAndOverlaysWhenTooWide() {
    let screen = NSRect(x: -1600, y: 0, width: 1600, height: 900)
    let frame = NSRect(x: -1600, y: 30, width: 900, height: 700)
    let result = LibraryLayout.paneFrame(frame: frame, screen: screen, delta: 280, left: true)
    XCTAssertEqual(result?.minX, screen.minX)
    XCTAssertEqual(result?.width, 1180)
    XCTAssertNil(LibraryLayout.paneFrame(frame: frame, screen: screen, delta: 800, left: false))
  }

  func testContentMinimumIncludesOnlyDockedPanes() {
    XCTAssertEqual(LibraryLayout.minimumWidth(left: 280, right: 360), 1280)
    XCTAssertEqual(LibraryLayout.minimumWidth(left: 0, right: 0), 640)
    XCTAssertEqual(LibraryLayout.boundedPaneWidth(20, left: true), 240)
    XCTAssertEqual(LibraryLayout.boundedPaneWidth(900, left: true), 420)
  }

  func testLibrarySortAndFiltersPreserveMissingItems() {
    let items = [item("Zulu", progress: 0.5), item("Alpha", missing: true), item("Beta", progress: 1)]
    XCTAssertEqual(LibraryQuery.apply(items, query: "", sort: .title, filter: .all).map(\.title),
                   ["Alpha", "Beta", "Zulu"])
    XCTAssertEqual(LibraryQuery.apply(items, query: "", sort: .title, filter: .missing).map(\.title), ["Alpha"])
    XCTAssertEqual(LibraryQuery.apply(items, query: "", sort: .title, filter: .unfinished).map(\.title), ["Alpha", "Zulu"])
    XCTAssertEqual(LibraryQuery.apply(items, query: "fix", sort: .title, filter: .all).count, 3)
  }

  func testSnapshotKeepsPresenceUnknownAndAppliesHiddenWatchedOverrides() {
    let url = URL(fileURLWithPath: "/uniplayer-missing-fixture/film.mp4")
    let entry = PlaybackHistorySnapshot(
      url: url, name: url.lastPathComponent, played: true, addedDate: Date(),
      duration: 100, progress: nil, title: "Film")
    let snapshot = LibraryModel.snapshot(history: [entry], recent: [], lastPlayed: url,
      hidden: [], watched: [url.standardizedFileURL.path: true])
    XCTAssertEqual(snapshot.allItems.count, 1)
    // The snapshot never probes the source path; the catalog's bounded workers
    // decide presence later.
    XCTAssertFalse(snapshot.allItems[0].isMissing)
    XCTAssertTrue(snapshot.allItems[0].isFinished)
    XCTAssertEqual(snapshot.hero?.url, url)
    let hidden = LibraryModel.snapshot(history: [entry], recent: [], lastPlayed: url,
      hidden: [url.standardizedFileURL.path], watched: [:])
    XCTAssertTrue(hidden.allItems.isEmpty)
  }

  func testNativeSliderCommitsNonMouseChanges() {
    var value = 0.0
    let view = InlineSlider(value: .init(get: { value }, set: { value = $0 }),
                            range: 0...100, label: "Position")
    let coordinator = view.makeCoordinator()
    let slider = NSSlider(value: 42, minValue: 0, maxValue: 100, target: nil, action: nil)
    coordinator.valueChanged(slider)
    XCTAssertEqual(value, 42)
  }
}

@MainActor
final class AssistantRemediationTests: XCTestCase {
  private final class EmptyExecutor: AssistantToolExecuting {
    func seek(to seconds: Double) -> Bool { false }
    func currentSubtitle() -> String? { nil }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "" }
  }
  func testSuggestionsDoNotPromiseUnseenVideoSummary() {
    let model = AssistantViewModel(toolExecutor: EmptyExecutor())
    XCTAssertFalse(model.suggestedPrompts.contains { $0.contains("Summarize this video") })
    XCTAssertFalse(model.suggestedPrompts.contains { $0.contains("Translate") })
    model.setChannelContext(ChannelPageContext(title: "A page", url: URL(string: "https://example.com")!, selection: nil))
    XCTAssertFalse(model.suggestedPrompts.contains { $0.contains("selected text") })
  }
}

@MainActor
final class LibraryMenuRoutingTests: XCTestCase {
  func testProgrammaticResizeCannotShrinkTheCentralViewportBelowItsMinimum() throws {
    let controller = LibraryWindowController(playerCore: PlayerCore.first)
    controller.showWindow(nil)
    defer { controller.close() }
    let window = try XCTUnwrap(controller.window)
    var frame = window.frame
    frame.size.width = 700
    window.setFrame(frame, display: false)
    controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
    XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
    XCTAssertGreaterThanOrEqual(window.frame.width,
      Tokens.Library.contentMinimumWidth + Tokens.Library.outwardSidebarMinimum)
  }

  func testLeavingWindowFullscreenKeepsActiveFocusModePanesHidden() throws {
    let chrome = LibraryChrome()
    let controller = LibraryWindowController(playerCore: PlayerCore.first, chrome: chrome)
    controller.showWindow(nil)
    defer { controller.close() }
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 100, y: 100, width: 1220, height: 760), display: false)
    let original = window.frame
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    controller.toggleFocusMode()
    window.setFrame(original, display: false)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    XCTAssertTrue(controller.isFocusMode)
    XCTAssertEqual(chrome.columnVisibility, .detailOnly)
    XCTAssertFalse(chrome.inspectorPresented)
    XCTAssertEqual(window.frame.width, original.width - chrome.sidebarWidth, accuracy: 1)
    controller.toggleFocusMode()
    XCTAssertEqual(chrome.columnVisibility, .all)
    XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
  }

  func testFocusModeEndedInsideWindowFullscreenRestoresPanesOnExit() throws {
    let chrome = LibraryChrome()
    let controller = LibraryWindowController(playerCore: PlayerCore.first, chrome: chrome)
    controller.showWindow(nil)
    defer { controller.close() }
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 100, y: 100, width: 1220, height: 760), display: false)
    let original = window.frame
    controller.toggleFocusMode()
    let focusedFrame = window.frame
    controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
    controller.toggleFocusMode()
    window.setFrame(focusedFrame, display: false)
    controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
    XCTAssertFalse(controller.isFocusMode)
    XCTAssertEqual(chrome.columnVisibility, .all)
    XCTAssertTrue(chrome.leftDocked)
    XCTAssertEqual(window.frame.width, original.width, accuracy: 1)
  }

  func testLibraryWindowDispatchesMenuCommandsThroughItsResponderChain() throws {
    let controller = LibraryWindowController(playerCore: PlayerCore.first)
    controller.showWindow(nil)
    defer { controller.close() }
    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.tryToPerform(#selector(MainMenuActionHandler.menuSearchLibrary(_:)), with: nil))
    XCTAssertTrue(window.nextResponder?.responds(to: #selector(MainMenuActionHandler.menuTogglePause(_:))) == true)
  }
}

@MainActor
final class VideoFullscreenHostTests: XCTestCase {
  func testMovingStableHostToFullscreenAndBackDoesNotLoseSurface() {
    let host = InlinePlayerSurfaceHost()
    let surface = NSView()
    let mover = PlayerSurfaceMover(surface: surface)
    mover.attach(to: host)
    let inline = InlinePlayerWrapperView(host: host)
    let fullscreen = InlinePlayerWrapperView(host: host)
    inline.detachHost() // SwiftUI dismantles the old inline wrapper later.
    XCTAssertTrue(host.superview === fullscreen)
    XCTAssertTrue(surface.superview === host)
    inline.attachHost()
    fullscreen.detachHost() // Late fullscreen teardown must not steal it back.
    XCTAssertTrue(host.superview === inline)
    XCTAssertTrue(surface.superview === host)
  }

  func testOnlyDoubleLeftMouseUpRequestsVideoFullscreen() {
    let host = InlinePlayerSurfaceHost()
    var count = 0
    host.onDoubleClick = { count += 1 }
    for (kind, clicks) in [(NSEvent.EventType.leftMouseUp, 1), (.rightMouseUp, 2), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
      let event = NSEvent.mouseEvent(with: kind, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
      host.handleSurfaceEvent(event)
    }
    XCTAssertEqual(count, 1)
  }
}

@MainActor
final class ChannelConnectionTests: XCTestCase {
  func testRetryAfterAnInitialConnectionFailureStartsAFreshNavigation() async throws {
    let browser = ChannelBrowserModel()
    let failure = expectation(description: "Initial connection refused")
    let observation = browser.$errorMessage.compactMap { $0 }.prefix(1).sink { _ in failure.fulfill() }
    defer { observation.cancel(); browser.stop() }
    browser.open(Channel(id: "connection-test", name: "Test Channel",
      url: URL(string: "http://127.0.0.1:1/")!, symbol: "globe"))
    await fulfillment(of: [failure], timeout: 5)
    XCTAssertNotNil(browser.errorMessage)
    browser.reload()
    XCTAssertTrue(browser.isLoading)
    XCTAssertNil(browser.errorMessage)
  }

  func testConnectionGuidanceDistinguishesOfflineAndCertificateFailures() {
    let offline = ChannelConnectionIssue(error: URLError(.notConnectedToInternet))
    let certificate = ChannelConnectionIssue(error: URLError(.serverCertificateUntrusted))
    XCTAssertEqual(offline.title, "You’re offline")
    XCTAssertEqual(certificate.title, "A secure connection couldn’t be established")
    XCTAssertNotEqual(offline.explanation, certificate.explanation)
  }
}

private final class RecoveryAssistantProvider: AssistantProvider {
  let identifier = "recovery-fixture"
  var requests: [AssistantRequest] = []
  func stream(_ request: AssistantRequest, configuration: AssistantConfiguration)
    -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    requests.append(request)
    let first = requests.count == 1
    return AsyncThrowingStream { continuation in
      continuation.yield(.text(first ? "Partial answer" : "Recovered answer"))
      continuation.finish(throwing: first ? AssistantError.offline : nil)
    }
  }
}

@MainActor
final class AssistantRecoveryTests: XCTestCase {
  private final class Executor: AssistantToolExecuting {
    func seek(to seconds: Double) -> Bool { false }
    func currentSubtitle() -> String? { nil }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "" }
  }
  private func model(_ provider: RecoveryAssistantProvider) -> AssistantViewModel {
    AssistantViewModel(toolExecutor: Executor(), service: AssistantService { _ in provider },
      configurationProvider: { AssistantConfiguration(provider: .openAICompatible,
        endpoint: "http://localhost/v1/chat/completions", model: "fixture", apiKey: nil) })
  }
  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
  func testRetryPreservesPartialAnswerWithoutDuplicatingTheQuestion() async {
    let provider = RecoveryAssistantProvider()
    let model = model(provider)
    model.send("Explain this timestamp")
    await waitFor { model.errorMessage != nil }
    XCTAssertTrue(model.canRetry)
    XCTAssertEqual(model.responseAnnouncement, "Assistant request failed.")
    model.retry()
    await waitFor { model.transcript.last?.text == "Recovered answer" && !model.isStreaming }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertEqual(provider.requests.last?.messages.filter { $0.role == .user }.count, 1)
    XCTAssertEqual(model.transcript.filter { $0.kind == .user }.count, 1)
    XCTAssertTrue(model.transcript.contains { $0.text == "Partial answer" && $0.isPartial })
  }
  func testDismissingFailurePreservesConversation() async {
    let model = model(RecoveryAssistantProvider())
    model.send("Keep this question")
    await waitFor { model.errorMessage != nil }
    model.dismissError()
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.canRetry)
    XCTAssertTrue(model.transcript.contains { $0.text == "Keep this question" })
  }
  func testRecoveryRoutesCredentialFailuresToSettings() {
    XCTAssertTrue(AssistantError.unauthorized.needsSettingsCorrection)
    XCTAssertTrue(AssistantError.missingAPIKey.needsSettingsCorrection)
    XCTAssertFalse(AssistantError.offline.needsSettingsCorrection)
  }
}

private final class CaptureAssistantProvider: AssistantProvider {
  let identifier = "capture-fixture"
  private var calls = 0
  func stream(_ request: AssistantRequest, configuration: AssistantConfiguration)
    -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    calls += 1
    let fail = calls == 1
    return AsyncThrowingStream { continuation in
      let task = Task {
        if fail {
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled else { return }
          continuation.finish(throwing: AssistantError.offline)
        } else {
          continuation.yield(.text("The connection recovered. Your original question is still here."))
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

@MainActor
final class UISweepCaptureTests: XCTestCase {
  private final class Executor: AssistantToolExecuting {
    func seek(to seconds: Double) -> Bool { false }
    func currentSubtitle() -> String? { nil }
    func relatedItems(matching query: String) -> [String] { [] }
    func rangeDescription(start: Double, end: Double) -> String { "" }
  }
  private let output = URL(fileURLWithPath: "/tmp/uniplayer-ui-sweep-evidence")
  private func enabled() throws {
    guard FileManager.default.fileExists(atPath: "/tmp/uniplayer-ui-sweep-capture.enabled") else {
      throw XCTSkip("Opt-in native capture on the E2E Mac")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    NSApp.setActivationPolicy(.regular)
  }
  private func capture(_ window: NSWindow, _ name: String) async throws {
    if let parent = window.sheetParent { parent.makeKeyAndOrderFront(nil) }
    else { window.makeKeyAndOrderFront(nil) }
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(400))
    window.displayIfNeeded()
    let request = output.appendingPathComponent("capture-request.json")
    let response = output.appendingPathComponent("capture-response.json")
    try? FileManager.default.removeItem(at: response)
    let payload: [String: Any] = ["window": window.windowNumber, "name": name,
      "visible": window.isVisible, "pid": ProcessInfo.processInfo.processIdentifier]
    try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: response.path) {
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any]
        XCTAssertEqual(result?["success"] as? Bool, true, "External E2E capture failed")
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("External E2E capture worker did not respond")
  }

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
  func testAssistantNativeRecoveryCaptures() async throws {
    try enabled()
    let provider = CaptureAssistantProvider()
    let model = AssistantViewModel(toolExecutor: Executor(), service: AssistantService { _ in provider },
      configurationProvider: { AssistantConfiguration(provider: .openAICompatible,
        endpoint: "http://localhost/v1/chat/completions", model: "fixture", apiKey: nil) })
    let window = NSWindow(contentRect: NSRect(x: 300, y: 100, width: 360, height: 760),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Assistant review"
    window.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: AIInspectorView(model: model).environment(\.libraryTextScale, 1))
    host.sizingOptions = []
    window.contentView = host
    defer { model.stop(); window.close() }
    model.send("Explain the attached context")
    try await capture(window, "assistant-waiting")
    for _ in 0..<100 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(model.errorMessage)
    try await capture(window, "assistant-failure")
    host.rootView = AIInspectorView(model: model).environment(\.libraryTextScale, 2)
    window.setContentSize(NSSize(width: 260, height: 508))
    try await capture(window, "assistant-failure-200")
    model.retry()
    for _ in 0..<100 {
      if !model.isStreaming { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.transcript.filter { $0.kind == .user }.count, 1)
    host.rootView = AIInspectorView(model: model).environment(\.libraryTextScale, 1)
    window.setContentSize(NSSize(width: 360, height: 760))
    try await capture(window, "assistant-recovered")
    window.contentView = NSHostingView(rootView: ZStack {
      Tokens.Palette.black.color
      InlineLoadingIndicator(message: "Opening video…")
    })
    window.setContentSize(NSSize(width: 640, height: 360))
    try await capture(window, "inline-opening")
  }
  func testPluginNativeRecoveryCaptures() async throws {
    try enabled()
    let root = output.appendingPathComponent("plugin-fixture.iinaplugin")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["name": "Recovery Preview — a deliberately long plugin name", "identifier": "org.uniplayer.ui-sweep",
      "author": ["name": "Local fixture"], "version": "1.0", "entry": "main.js", "helpPage": "help.html", "preferenceDefaults": [:]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("Info.json"))
    try Data().write(to: root.appendingPathComponent("main.js"))
    let help = root.appendingPathComponent("help.html")
    try Data("<title>Help</title>".utf8).write(to: help)
    let plugin = try XCTUnwrap(JavascriptPlugin(filename: root.lastPathComponent, externalURL: root))
    let parent = NSWindow()
    parent.isReleasedWhenClosed = false
    let window = PluginDetailsWindow(plugin: plugin, window: parent)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    parent.setContentSize(NSSize(width: 800, height: 650))
    parent.makeKeyAndOrderFront(nil)
    parent.beginSheet(window, completionHandler: nil)
    defer {
      parent.endSheet(window)
      window.close(); parent.close()
      try? FileManager.default.removeItem(at: Utility.pluginsURL.appendingPathComponent(".preferences/org.uniplayer.ui-sweep.plist"))
    }
    try await capture(window, "plugin-no-settings")
    try FileManager.default.removeItem(at: help)
    let segment = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSSegmentedControl }.first)
    let nameLabel = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == plugin.name })
    XCTAssertLessThanOrEqual(nameLabel.frame.maxX, segment.frame.minX)
    segment.selectedSegment = 2
    NSApp.sendAction(try XCTUnwrap(segment.action), to: segment.target, from: segment)
    for _ in 0..<100 {
      if descendants(window.contentView!).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "Couldn’t load the plugin page" }) { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let retry = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Try Again" })
    XCTAssertFalse(retry.isHidden)
    try await capture(window, "plugin-failure")
    try Data("<title>Recovered help</title><h1>Plugin help is ready</h1>".utf8).write(to: help)
    retry.performClick(nil)
    let webView = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? WKWebView }.first)
    for _ in 0..<100 {
      if !webView.isLoading, webView.url == help { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let title = try await webView.evaluateJavaScript("document.title") as? String
    XCTAssertEqual(title, "Recovered help")
    try await capture(window, "plugin-recovered")
  }
}

final class RecoveryPresentationTests: XCTestCase {
  func testInlineLoadingStatusTracksOpeningAndRespectsBufferingPreference() {
    XCTAssertEqual(InlineLoadingStatus.message(state: .loading, pausedForCache: false, showBuffering: false), "Opening video…")
    XCTAssertEqual(InlineLoadingStatus.message(state: .playing, pausedForCache: true, showBuffering: true), "Buffering…")
    XCTAssertNil(InlineLoadingStatus.message(state: .playing, pausedForCache: true, showBuffering: false))
    XCTAssertNil(InlineLoadingStatus.message(state: .idle, pausedForCache: true, showBuffering: true))
  }
  func testPluginInstallAlertDoesNotEmbedUnboundedProcessOutput() {
    let diagnostic = String(repeating: "process diagnostic line\n", count: 2000)
    let error = JavascriptPlugin.PluginError.cannotDownload(diagnostic, diagnostic)
    let message = PluginInstallErrorMessage.message(for: error)
    XCTAssertLessThan(message.count, 500)
    XCTAssertFalse(message.contains("process diagnostic line"))
  }
}
