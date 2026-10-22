//
//  AIInspectorView.swift
//  uniplayer
//
//  The right inspector: a transcript, an explicit context disclosure, and the
//  controls that send, stop and clear a request. It talks to PlayerCore only
//  through the view model, and it never sends media.
//

import AppKit
import SwiftUI

private func aiL(_ key: String) -> String {
  NSLocalizedString(key, comment: "")
}

// MARK: - View model

@MainActor
final class AssistantViewModel: ObservableObject {

  struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
      case user
      case assistant
      case notice
    }

    let id: UUID
    let kind: Kind
    var text: String
    var isPartial: Bool

    init(id: UUID = UUID(), kind: Kind, text: String, isPartial: Bool = false) {
      self.id = id
      self.kind = kind
      self.text = text
      self.isPartial = isPartial
    }
  }

  enum State: Equatable {
    case idle
    case streaming
    case failed(AssistantError)
  }

  @Published private(set) var transcript: [TranscriptItem] = []
  @Published var draft = ""
  @Published private(set) var state: State = .idle
  @Published private(set) var playerContext: PlaybackContext?
  @Published private(set) var channelContext: ChannelPageContext?
  @Published private(set) var pendingTool: AssistantTypedToolCall?
  /// Every call awaiting the same confirmation, so the banner can disclose
  /// exactly what Allow will run.
  private(set) var queuedToolCalls: [AssistantTypedToolCall] = []
  @Published var includeFilePath = false

  /// Called when the user clicks a timestamp chip.
  var onSeek: ((Double) -> Void)?
  /// Called after a tool changed playback, so the inline controls refresh.
  var onToolPlaybackChanged: (() -> Void)?
  /// Supplies the explicit context. Nothing is captured until it is needed.
  var playerContextProvider: ((Bool) -> PlaybackContext?)?
  /// Identifies the file the confirmation was requested against.
  var currentMediaID: (() -> String?)?

  static let maxToolRounds = 3

  private let service: AssistantService
  private let configurationProvider: () -> AssistantConfiguration
  private let toolExecutor: AssistantToolExecuting
  private var providerMessages: [AssistantProviderMessage] = []
  private var streamingItemID: UUID?
  private var toolRounds = 0
  /// Distinguishes callbacks from an abandoned request, so a cancelled stream
  /// cannot write into the next answer.
  private var requestGeneration = 0
  /// The one context message in the provider history. It is replaced on every
  /// send, so a withdrawn file-path opt-in removes earlier paths too.
  private var contextMessageIndex: Int?
  private var hasSystemPrompt = false
  /// The media the pending confirmation was requested against.
  private var pendingToolMedia: String?
  /// Every full path the user has approved, so revoking consent can scrub all
  /// of them from retained history.
  private var includedPaths: Set<String> = []
  /// Paths whose consent was revoked; every later history write is sanitized
  /// too, including text that arrives after the toggle.
  private var revokedPaths: [String: String] = [:]
  /// The media that was playing when the current request started; tool
  /// confirmations must target that file, not whatever plays at reply time.
  private var requestMediaID: String?

  init(toolExecutor: AssistantToolExecuting,
       service: AssistantService = AssistantService(),
       configurationProvider: @escaping () -> AssistantConfiguration = { .load() }) {
    self.toolExecutor = toolExecutor
    self.service = service
    self.configurationProvider = configurationProvider
  }

  var isStreaming: Bool {
    if case .streaming = state { return true }
    return false
  }

  var errorMessage: String? {
    if case .failed(let error) = state { return error.errorDescription }
    return nil
  }

  var contextDisclosure: String? {
    if let channelContext { return channelContext.disclosure }
    return playerContext?.disclosure
  }

  var hasContext: Bool {
    channelContext != nil || playerContext != nil
  }

  // MARK: Context

  /// Reads the current context. Called when the inspector appears and before
  /// every send; it never sends anything by itself.
  func refreshContext() {
    if let playerContextProvider {
      let context = playerContextProvider(includeFilePath)
      playerContext = context
      if let path = context?.filePath, !path.isEmpty {
        includedPaths.insert(path)
      }
    }
  }

  /// A channel page offers its context only after the user asks for it.
  func setChannelContext(_ context: ChannelPageContext?) {
    channelContext = context
  }

  /// The single write path for provider history. Text produced after a
  /// consent withdrawal must be scrubbed too, not just what was retained at
  /// the moment of withdrawal.
  private func record(_ message: AssistantProviderMessage) {
    providerMessages.append(sanitized(message))
  }

  private func sanitized(_ message: AssistantProviderMessage) -> AssistantProviderMessage {
    guard !revokedPaths.isEmpty else { return message }
    var message = message
    for (path, name) in revokedPaths {
      message.content = AssistantRedaction.scrub(
        message.content, path: path, replacement: name)
      for index in message.toolCalls.indices {
        let call = message.toolCalls[index]
        message.toolCalls[index] = AssistantToolCall(
          id: call.id,
          name: call.name,
          argumentsJSON: AssistantRedaction.scrub(
            call.argumentsJSON, path: path, replacement: name))
      }
    }
    return message
  }

  private var systemPrompt: String {
    aiL("You are the assistant inside a desktop video player. Use only the explicit context in each message. You cannot see video frames. Write times as mm:ss or h:mm:ss. To move playback, call the seek tool; never claim playback moved without calling it.")
  }

  // MARK: Sending

  func send(_ text: String? = nil) {
    let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
    // A pending confirmation owns the conversation until it is resolved.
    guard !message.isEmpty, !isStreaming, pendingTool == nil else { return }
    refreshContext()
    ensureSystemPrompt()
    syncContextMessage()
    transcript.append(TranscriptItem(kind: .user, text: message))
    draft = ""
    toolRounds = 0
    requestMediaID = currentMediaID?()
    record(AssistantProviderMessage(role: .user, content: message))
    runStream()
  }

  func stop() {
    // A finished stream can still own queued tool calls awaiting confirmation.
    guard isStreaming || pendingTool != nil || !queuedToolCalls.isEmpty else { return }
    requestGeneration += 1
    service.cancel()
    let partial = finishStreamingItem(partial: true)
    if !partial.isEmpty {
      // The displayed partial answer must reach provider history too, or a
      // follow-up such as "continue" has nothing to continue from.
      record(AssistantProviderMessage(
        role: .assistant, content: partial + "\n\n[interrupted by user]"))
    }
    for call in queuedToolCalls {
      record(AssistantProviderMessage(
        role: .tool, content: aiL("Cancelled by the user."), toolCallID: call.id))
    }
    pendingTool = nil
    queuedToolCalls = []
    pendingToolMedia = nil
    transcript.append(TranscriptItem(kind: .notice, text: aiL("Stopped.")))
    state = .idle
  }

  /// Withdrawing the path opt-in must also remove every path retained in
  /// earlier approved messages and tool arguments.
  func revokeFilePathConsent() {
    guard includeFilePath else { return }
    includeFilePath = false
    for index in providerMessages.indices {
      for path in includedPaths where !path.isEmpty {
        let name = (path as NSString).lastPathComponent
        providerMessages[index].content = AssistantRedaction.scrub(
          providerMessages[index].content, path: path, replacement: name)
        for callIndex in providerMessages[index].toolCalls.indices {
          let call = providerMessages[index].toolCalls[callIndex]
          providerMessages[index].toolCalls[callIndex] = AssistantToolCall(
            id: call.id,
            name: call.name,
            argumentsJSON: AssistantRedaction.scrub(
              call.argumentsJSON, path: path, replacement: name))
        }
      }
    }
    for path in includedPaths where !path.isEmpty {
      revokedPaths[path] = (path as NSString).lastPathComponent
    }
    includedPaths.removeAll()
    refreshContext()
    if contextMessageIndex != nil {
      syncContextMessage()
    }
  }

  func clear() {
    requestGeneration += 1
    service.cancel()
    transcript.removeAll()
    providerMessages.removeAll()
    queuedToolCalls.removeAll()
    pendingTool = nil
    streamingItemID = nil
    contextMessageIndex = nil
    hasSystemPrompt = false
    state = .idle
  }

  // MARK: Streaming

  private func ensureSystemPrompt() {
    guard !hasSystemPrompt else { return }
    providerMessages.insert(
      AssistantProviderMessage(role: .system, content: systemPrompt), at: 0)
    hasSystemPrompt = true
    if let contextMessageIndex {
      self.contextMessageIndex = contextMessageIndex + 1
    }
  }

  /// Keeps exactly one context message in history, current for this request.
  private func syncContextMessage() {
    let content = "Context:\n\(contextDisclosure ?? "No additional context.")"
    if let index = contextMessageIndex, index < providerMessages.count {
      providerMessages[index] = sanitized(
        AssistantProviderMessage(role: .system, content: content))
    } else {
      let index = min(1, providerMessages.count)
      providerMessages.insert(
        AssistantProviderMessage(role: .system, content: content), at: index)
      contextMessageIndex = index
    }
  }

  private func runStream() {
    ensureSystemPrompt()
    startStream()
  }

  private func startStream() {
    let configuration = configurationProvider()
    guard configuration.isConfigured else {
      state = .failed(.notConfigured)
      return
    }
    let item = TranscriptItem(kind: .assistant, text: "", isPartial: true)
    transcript.append(item)
    streamingItemID = item.id
    state = .streaming

    let request = AssistantRequest(
      messages: providerMessages,
      tools: AssistantToolName.allCases.map(\.definition))
    requestGeneration += 1
    let generation = requestGeneration
    service.stream(
      configuration: configuration,
      request: request,
      onEvent: { [weak self] event in
        guard let self, self.requestGeneration == generation else { return }
        self.handle(event)
      },
      onError: { [weak self] error in
        guard let self, self.requestGeneration == generation else { return }
        self.handle(error)
      },
      onFinish: { [weak self] in
        guard let self, self.requestGeneration == generation else { return }
        self.handleFinish()
      })
  }

  private func handle(_ event: AssistantStreamEvent) {
    switch event {
    case .text(let chunk):
      appendToStreamingItem(chunk)
    case .toolCalls(let calls):
      handleToolCalls(calls)
    }
  }

  private func handleFinish() {
    guard isStreaming else { return }
    let text = finishStreamingItem(partial: false)
    if !text.isEmpty {
      // Later questions need the assistant's own earlier answer.
      record(AssistantProviderMessage(role: .assistant, content: text))
    }
    state = .idle
  }

  private func handle(_ error: AssistantError) {
    let partial = finishStreamingItem(partial: true)
    if !partial.isEmpty {
      record(AssistantProviderMessage(
        role: .assistant, content: partial + "\n\n[interrupted by an error]"))
    }
    if error == .cancelled {
      state = .idle
      return
    }
    state = .failed(error)
  }

  private func appendToStreamingItem(_ chunk: String) {
    guard let id = streamingItemID,
          let index = transcript.firstIndex(where: { $0.id == id }) else { return }
    transcript[index].text += chunk
  }

  /// - Returns: the text that was streaming, even when the empty item is
  ///   removed, so the caller can record it in provider history.
  @discardableResult
  private func finishStreamingItem(partial: Bool) -> String {
    guard let id = streamingItemID,
          let index = transcript.firstIndex(where: { $0.id == id }) else { return "" }
    let text = transcript[index].text
    transcript[index].isPartial = partial
    if text.isEmpty {
      transcript.remove(at: index)
    }
    streamingItemID = nil
    return text
  }

  // MARK: Tools

  private func handleToolCalls(_ calls: [AssistantToolCall]) {
    // Capture this response's own text before the empty item is removed; the
    // previous assistant answer is not part of this request.
    let assistantText = finishStreamingItem(partial: false)

    var typed: [AssistantTypedToolCall] = []
    var rejected: [(call: AssistantToolCall, message: String)] = []
    for call in calls {
      do {
        typed.append(try AssistantToolParser.parse(call))
      } catch {
        rejected.append((call, error.localizedDescription))
        transcript.append(TranscriptItem(
          kind: .notice,
          text: error.localizedDescription))
      }
    }

    // The assistant's tool request belongs in the provider history so a
    // follow-up request can reference it. Rejected calls get a result too, so
    // the history never contains an unanswered tool call.
    record(AssistantProviderMessage(
      role: .assistant, content: assistantText, toolCalls: calls))
    for item in rejected {
      record(AssistantProviderMessage(
        role: .tool, content: item.message, toolCallID: item.call.id))
    }

    guard !typed.isEmpty else {
      state = .idle
      return
    }

    if let confirmation = typed.first(where: { $0.requiresConfirmation }) {
      pendingTool = confirmation
      pendingToolMedia = requestMediaID
      queuedToolCalls = typed
      return
    }
    execute(typed)
  }

  func confirmPendingTool() {
    guard !queuedToolCalls.isEmpty else {
      pendingTool = nil
      return
    }
    // The file can change while the banner is up; never seek the new file
    // with a position meant for the old one. Compare unconditionally: a nil
    // capture (no media) against a now-loaded file is also a change.
    if currentMediaID?() != pendingToolMedia {
      transcript.append(TranscriptItem(
        kind: .notice,
        text: aiL("Playback changed before confirmation; the request was discarded.")))
      cancelPendingTool()
      return
    }
    let calls = queuedToolCalls
    pendingTool = nil
    pendingToolMedia = nil
    queuedToolCalls = []
    execute(calls)
  }

  func cancelPendingTool() {
    if let pending = pendingTool {
      transcript.append(TranscriptItem(
        kind: .notice,
        text: String(format: aiL("Cancelled %@."), pending.tool.rawValue)))
    }
    // Resolve the calls in history as well; an unanswered tool call makes the
    // next request invalid for strict providers.
    for call in queuedToolCalls {
      record(AssistantProviderMessage(
        role: .tool, content: aiL("Cancelled by the user."), toolCallID: call.id))
    }
    pendingTool = nil
    pendingToolMedia = nil
    queuedToolCalls = []
    state = .idle
  }

  private func execute(_ calls: [AssistantTypedToolCall]) {
    for call in calls {
      let result = AssistantToolExecutor.execute(call, executor: toolExecutor)
      record(AssistantProviderMessage(
        role: .tool, content: result, toolCallID: call.id))
      // Tool results are outgoing text too; show them in the transcript. A
      // long result is abbreviated here but the full text is still sent.
      let shown = result.count > 280
        ? String(result.prefix(280)) + aiL("… (full result sent)")
        : result
      transcript.append(TranscriptItem(
        kind: .notice,
        text: String(format: aiL("Tool %@ result: %@"), call.tool.rawValue, shown)))
      if case .seek = call.arguments {
        // The executor already moved playback; only refresh the controls.
        onToolPlaybackChanged?()
      }
    }
    toolRounds += 1
    guard toolRounds < Self.maxToolRounds else {
      transcript.append(TranscriptItem(
        kind: .notice,
        text: aiL("The assistant reached its tool limit for this message.")))
      state = .idle
      return
    }
    runStream()
  }

  // MARK: Suggested prompts

  var suggestedPrompts: [String] {
    if channelContext != nil {
      return [
        aiL("Summarize this page."),
        aiL("Explain the selected text."),
      ]
    }
    return [
      aiL("Summarize this video."),
      aiL("Translate the current subtitle."),
      aiL("What should I know before watching?"),
    ]
  }

  func sendSuggestedPrompt(_ prompt: String) {
    send(prompt)
  }
}

// MARK: - Inspector

struct AIInspectorView: View {
  @ObservedObject var model: AssistantViewModel
  @FocusState private var inputFocused: Bool
  @State private var disclosureExpanded = false
  private let contextTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: Tokens.Space.n0) {
      header
      Divider()
      transcript
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // The input and the context stay pinned; only the transcript scrolls.
    .safeAreaInset(edge: .bottom, spacing: Tokens.Space.n0) {
      VStack(spacing: Tokens.Space.n0) {
        pendingConfirmation
        errorBanner
        contextSection
        inputBar
      }
      .background(Tokens.Palette.surface.color)
    }
    .background(Tokens.Palette.surface.color)
    .onAppear {
      model.refreshContext()
    }
    .onChange(of: model.includeFilePath) { _, _ in
      model.refreshContext()
    }
    .onReceive(contextTimer) { _ in
      // Keep the preview honest: what is shown is what Send will attach.
      model.refreshContext()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(aiL("AI Assistant"))
  }

  private var header: some View {
    HStack(spacing: Tokens.Space.n8) {
      Text(aiL("AI Assistant"))
        .font(Tokens.Typography.sectionTitle.font)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
      Spacer()
      Button {
        model.clear()
      } label: {
        Image(systemName: "trash")
          .font(Tokens.Typography.caption.font)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Tokens.Palette.textSecondary.color)
      .disabled(model.transcript.isEmpty)
      .accessibilityLabel(aiL("Clear Conversation"))
      .help(aiL("Clear Conversation"))
    }
    .padding(.horizontal, Tokens.Space.n16)
    .padding(.vertical, Tokens.Space.n12)
  }

  @ViewBuilder
  private var transcript: some View {
    if model.transcript.isEmpty {
      ScrollView {
        emptyState
          .frame(maxWidth: .infinity)
      }
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Tokens.Space.n12) {
            ForEach(model.transcript) { item in
              bubble(item)
            }
            Tokens.Palette.clear.color
              .frame(height: Tokens.Space.n1)
              .id("bottom")
          }
          .padding(Tokens.Space.n16)
        }
        .onChange(of: model.transcript.last?.text) { _, _ in
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: Tokens.Space.n12) {
      Image(systemName: "sparkles")
        .font(.system(size: Tokens.Icon.n28, weight: .light))
        .foregroundStyle(Tokens.Palette.textSecondary.color)
      Text(aiL("Ask about what you are watching"))
        .font(Tokens.Typography.bodyStrong.font)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
      Text(aiL("Only the text shown under “What will be sent” leaves this Mac. Video frames and files are never sent."))
        .font(Tokens.Typography.caption.font)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: Tokens.Space.n8) {
        ForEach(model.suggestedPrompts, id: \.self) { prompt in
          Button(prompt) {
            model.sendSuggestedPrompt(prompt)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(.top, Tokens.Space.n4)
    }
    .padding(Tokens.Space.n24)
  }

  @ViewBuilder
  private func bubble(_ item: AssistantViewModel.TranscriptItem) -> some View {
    switch item.kind {
    case .user:
      Text(item.text)
        .font(Tokens.Typography.body.font)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .padding(Tokens.Space.n10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.controlBackground.color,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.n10, style: .continuous))
        .textSelection(.enabled)
    case .assistant:
      VStack(alignment: .leading, spacing: Tokens.Space.n4) {
        AssistantMessageText(text: item.text, onSeek: { seconds in
          model.onSeek?(seconds)
        })
        if item.isPartial, !model.isStreaming {
          Text(aiL("Stopped — partial answer"))
            .font(Tokens.Typography.caption.font)
            .foregroundStyle(Tokens.Palette.textTertiary.color)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
    case .notice:
      Text(item.text)
        .font(Tokens.Typography.caption.font)
        .foregroundStyle(Tokens.Palette.textSecondary.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var pendingConfirmation: some View {
    if model.pendingTool != nil {
      VStack(alignment: .leading, spacing: Tokens.Space.n8) {
        Text(pendingConfirmationText)
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textPrimary.color)
        HStack(spacing: Tokens.Space.n8) {
          Button(aiL("Allow")) {
            model.confirmPendingTool()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          Button(aiL("Cancel")) {
            model.cancelPendingTool()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(Tokens.Space.n12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Tokens.Palette.controlBackground.color)
    }
  }

  /// Allow runs every queued call, so every state-changing call is named.
  private var pendingConfirmationText: String {
    let confirmations = model.queuedToolCalls.filter(\.requiresConfirmation)
    guard !confirmations.isEmpty else {
      return aiL("The assistant wants to change playback.")
    }
    return confirmations.map(confirmationText).joined(separator: "\n")
  }

  private func confirmationText(_ call: AssistantTypedToolCall) -> String {
    switch call.arguments {
    case .seek(let seconds, let reason):
      let target = VideoTime(seconds).stringRepresentation
      if let reason {
        return String(format: aiL("The assistant wants to seek to %@: %@"), target, reason)
      }
      return String(format: aiL("The assistant wants to seek to %@."), target)
    default:
      return String(format: aiL("The assistant wants to run %@."), call.tool.rawValue)
    }
  }

  @ViewBuilder
  private var errorBanner: some View {
    if let error = model.errorMessage {
      HStack(alignment: .top, spacing: Tokens.Space.n8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Tokens.Palette.systemOrange.color)
        VStack(alignment: .leading, spacing: Tokens.Space.n4) {
          Text(error)
            .font(Tokens.Typography.caption.font)
            .foregroundStyle(Tokens.Palette.textPrimary.color)
          if case .failed(.notConfigured) = model.state {
            Button(aiL("Open Settings")) {
              SettingsWindow.default.show()
              SettingsWindow.default.navigateTo(page: "assistant")
            }
            .buttonStyle(.link)
            .controlSize(.small)
          }
        }
        Spacer(minLength: Tokens.Space.n0)
      }
      .padding(Tokens.Space.n12)
      .background(Tokens.Palette.controlBackground.color)
    }
  }

  // MARK: Context

  private var contextSection: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.n8) {
      if model.hasContext {
        contextChips
        // An explicit button, not DisclosureGroup: the inspector's inset is
        // not a form, and this keeps the label's whole row clickable.
        Button {
          disclosureExpanded.toggle()
        } label: {
          HStack(spacing: Tokens.Space.n4) {
            Image(systemName: disclosureExpanded ? "chevron.down" : "chevron.right")
              .font(Tokens.Typography.caption.font)
            Text(aiL("What will be sent"))
              .font(Tokens.Typography.caption.font)
          }
          .foregroundStyle(Tokens.Palette.textSecondary.color)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(aiL("What will be sent"))

        if disclosureExpanded {
          Text(model.contextDisclosure ?? "")
            .font(Tokens.Typography.codeSample.font)
            .foregroundStyle(Tokens.Palette.textSecondary.color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(aiL("Tool results from this context (subtitle, selection, library matches) are also sent and are shown in the transcript."))
            .font(Tokens.Typography.caption.font)
            .foregroundStyle(Tokens.Palette.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
          if model.playerContext != nil {
            Button {
              if model.includeFilePath {
                model.revokeFilePathConsent()
              } else {
                model.includeFilePath = true
                model.refreshContext()
              }
            } label: {
              HStack(spacing: Tokens.Space.n4) {
                Image(systemName: model.includeFilePath
                      ? "checkmark.square.fill" : "square")
                  .font(Tokens.Typography.caption.font)
                Text(aiL("Include full file path"))
                  .font(Tokens.Typography.caption.font)
              }
              .foregroundStyle(Tokens.Palette.textSecondary.color)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(aiL("Include full file path"))
            .accessibilityValue(model.includeFilePath ? aiL("On") : aiL("Off"))
          }
        }
      } else {
        Text(aiL("No context yet. Open a video or a channel to add context."))
          .font(Tokens.Typography.caption.font)
          .foregroundStyle(Tokens.Palette.textTertiary.color)
      }
    }
    .padding(.horizontal, Tokens.Space.n16)
    .padding(.vertical, Tokens.Space.n8)
  }

  private var contextChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Tokens.Space.n6) {
        if let channel = model.channelContext {
          chip(channel.title)
          chip(channel.source)
          if let selection = channel.selection {
            chip(selection)
          }
        } else {
          if let title = model.playerContext?.title {
            chip(title)
          }
          if let timestamp = model.playerContext?.timestamp,
             let position = model.playerContext?.position {
            Button {
              model.onSeek?(position)
            } label: {
              chipContent(symbol: "clock", text: timestamp)
            }
            .buttonStyle(.plain)
            .help(aiL("Seek to this position"))
          }
          if let subtitle = model.playerContext?.subtitleLine {
            chip(subtitle)
          }
        }
      }
    }
  }

  private func chip(_ text: String) -> some View {
    chipContent(symbol: nil, text: text)
  }

  private func chipContent(symbol: String?, text: String) -> some View {
    HStack(spacing: Tokens.Space.n4) {
      if let symbol {
        Image(systemName: symbol)
          .font(Tokens.Typography.caption.font)
      }
      Text(text)
        .font(Tokens.Typography.caption.font)
        .lineLimit(1)
    }
    .padding(.horizontal, Tokens.Space.n8)
    .padding(.vertical, Tokens.Space.n4)
    .background(Tokens.Palette.controlBackground.color, in: Capsule())
    .foregroundStyle(Tokens.Palette.textSecondary.color)
  }

  // MARK: Input

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: Tokens.Space.n8) {
      TextField(aiL("Ask about this video…"), text: $model.draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(Tokens.Typography.body.font)
        .lineLimit(1...4)
        .focused($inputFocused)
        .onSubmit { model.send() }
        .padding(Tokens.Space.n8)
        .background(Tokens.Palette.controlBackground.color,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.n8, style: .continuous))
        .accessibilityLabel(aiL("Message"))

      if model.isStreaming {
        Button {
          model.stop()
        } label: {
          Image(systemName: "stop.fill")
            .font(Tokens.Typography.body.font)
            .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.Palette.textPrimary.color)
        .accessibilityLabel(aiL("Stop"))
        .help(aiL("Stop"))
      } else {
        Button {
          model.send()
        } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: Tokens.Icon.n24))
            .frame(width: Tokens.Size.n30, height: Tokens.Size.n30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? Tokens.Palette.textTertiary.color
                         : Tokens.Palette.textPrimary.color)
        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || model.pendingTool != nil)
        .accessibilityLabel(aiL("Send"))
        .help(aiL("Send"))
      }
    }
    .padding(Tokens.Space.n12)
  }
}

// MARK: - Linked assistant text

/// Renders assistant text with clickable timestamps. Parsing is done directly
/// into `AttributedString`, so the text does not reflow between deltas.
private struct AssistantMessageText: View {
  let text: String
  let onSeek: (Double) -> Void

  var body: some View {
    Text(attributed)
      .font(Tokens.Typography.body.font)
      .foregroundStyle(Tokens.Palette.textPrimary.color)
      .fixedSize(horizontal: false, vertical: true)
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "uniplayer-seek",
              let seconds = Double(url.host ?? "") else { return .systemAction }
        onSeek(seconds)
        return .handled
      })
  }

  private var attributed: AttributedString {
    var result = AttributedString(text)
    guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b"#) else {
      return result
    }
    let source = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
    for match in matches {
      guard let whole = Range(match.range, in: text) else { continue }
      let first = Int(source.substring(with: match.range(at: 1))) ?? 0
      let second = Int(source.substring(with: match.range(at: 2))) ?? 0
      let hasHours = match.range(at: 3).location != NSNotFound
      let third = hasHours ? (Int(source.substring(with: match.range(at: 3))) ?? 0) : 0
      // Two groups are minutes:seconds; three are hours:minutes:seconds.
      let hours = hasHours ? first : 0
      let minutes = hasHours ? second : first
      let seconds = hasHours ? third : second
      let total = Double(hours * 3600 + minutes * 60 + seconds)
      guard let lower = AttributedString.Index(whole.lowerBound, within: result),
            let upper = AttributedString.Index(whole.upperBound, within: result) else { continue }
      result[lower..<upper].link = URL(string: "uniplayer-seek://\(String(format: "%.0f", total))")
      result[lower..<upper].foregroundColor = Tokens.Palette.accent.color
    }
    return result
  }
}
