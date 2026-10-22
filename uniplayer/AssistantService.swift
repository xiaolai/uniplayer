//
//  AssistantService.swift
//  uniplayer
//
//  A provider-agnostic assistant client. It streams over URLSession with no
//  SDK: a local OpenAI-compatible endpoint is the default, and a Claude
//  adapter implements the same protocol. The API key lives in the Keychain and
//  is never written to defaults, logs or error messages.
//

import Foundation

// MARK: - Configuration

enum AssistantProviderKind: String, CaseIterable, Identifiable {
  case openAICompatible = "openai-compatible"
  case claude = "claude"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openAICompatible: return NSLocalizedString("OpenAI-compatible", comment: "Assistant provider")
    case .claude: return NSLocalizedString("Claude", comment: "Assistant provider")
    }
  }

  var defaultEndpoint: String {
    switch self {
    case .openAICompatible: return "http://127.0.0.1:11434/v1/chat/completions"
    case .claude: return "https://api.anthropic.com/v1/messages"
    }
  }

  var defaultModel: String {
    switch self {
    case .openAICompatible: return ""
    case .claude: return "claude-sonnet-5-5"
    }
  }
}

struct AssistantConfiguration: Equatable {
  var provider: AssistantProviderKind
  var endpoint: String
  var model: String
  var apiKey: String?

  var endpointURL: URL? {
    guard let url = URL(string: endpoint),
          url.scheme == "https" || url.scheme == "http" else { return nil }
    return url
  }

  /// A local endpoint (Ollama and friends) usually accepts requests without a
  /// credential, so requiring one would make the default unusable. Plain HTTP
  /// on a loopback, link-local or private address is treated as a LAN service.
  var requiresAPIKey: Bool {
    guard let url = endpointURL, let host = url.host?.lowercased() else { return true }
    // Only plain HTTP is treated as a credential-free LAN service; HTTPS is
    // never assumed to be unauthenticated.
    guard url.scheme == "http" else { return true }
    if host == "localhost" || host == "::1" { return false }
    if host.hasSuffix(".local") { return false }
    // Check valid IPv4 literals, not prefixes: `10.example.com` is public and
    // `10.1.2.999` is not an address at all.
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4 {
      let octets = parts.compactMap { Int($0) }
      if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
        let first = octets[0]
        let second = octets[1]
        if first == 127 { return false }               // loopback /8
        if first == 10 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 169, second == 254 { return false }
      }
    }
    return true
  }

  var isConfigured: Bool {
    guard endpointURL != nil, !model.isEmpty else { return false }
    return !requiresAPIKey || apiKey?.isEmpty == false
  }

  /// Reads the current settings on every call, so a settings change applies to
  /// the next request without a restart.
  static func load() -> AssistantConfiguration {
    let provider = AssistantProviderKind(
      rawValue: Preference.string(for: .assistantProvider) ?? "") ?? .openAICompatible
    var endpoint = Preference.string(for: .assistantEndpoint) ?? ""
    if endpoint.isEmpty { endpoint = provider.defaultEndpoint }
    var model = Preference.string(for: .assistantModel) ?? ""
    if model.isEmpty { model = provider.defaultModel }
    let key = (try? KeychainAccess.read(
      username: nil, forService: .assistantAPIKey))?.password
    return AssistantConfiguration(
      provider: provider, endpoint: endpoint, model: model, apiKey: key)
  }
}

// MARK: - Errors

enum AssistantError: LocalizedError, Equatable {
  case notConfigured
  case invalidEndpoint
  case missingAPIKey
  case unauthorized
  case httpStatus(Int)
  case offline
  case timedOut
  case malformedResponse
  case cancelled
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return NSLocalizedString("Set an endpoint, model and API key in Settings › AI.", comment: "Assistant error")
    case .invalidEndpoint:
      return NSLocalizedString("The assistant endpoint is not a valid HTTP or HTTPS URL.", comment: "Assistant error")
    case .missingAPIKey:
      return NSLocalizedString("No API key is stored for the assistant.", comment: "Assistant error")
    case .unauthorized:
      return NSLocalizedString("The assistant rejected the API key.", comment: "Assistant error")
    case .httpStatus(let code):
      return String(format: NSLocalizedString("The assistant returned HTTP %d.", comment: "Assistant error"), code)
    case .offline:
      return NSLocalizedString("The assistant endpoint is unreachable.", comment: "Assistant error")
    case .timedOut:
      return NSLocalizedString("The assistant request timed out.", comment: "Assistant error")
    case .malformedResponse:
      return NSLocalizedString("The assistant returned a response this app could not read.", comment: "Assistant error")
    case .cancelled:
      return NSLocalizedString("The request was cancelled.", comment: "Assistant error")
    case .provider(let message):
      return message
    }
  }
}

// MARK: - Request and events

struct AssistantProviderMessage: Equatable {
  enum Role: String {
    case system
    case user
    case assistant
    case tool
  }

  var role: Role
  var content: String
  var toolCalls: [AssistantToolCall] = []
  var toolCallID: String?
}

struct AssistantRequest {
  var messages: [AssistantProviderMessage]
  var tools: [AssistantToolDefinition]
}

/// Pieces a provider stream produces. Text arrives in deltas; tool calls are
/// complete only at the end of the response.
enum AssistantStreamEvent: Equatable {
  case text(String)
  case toolCalls([AssistantToolCall])
}

protocol AssistantProvider {
  var identifier: String { get }
  func stream(_ request: AssistantRequest,
              configuration: AssistantConfiguration) -> AsyncThrowingStream<AssistantStreamEvent, Error>
}

// MARK: - SSE parsing

/// A minimal Server-Sent Events parser. Both supported providers put one
/// complete JSON payload per `data:` line, so each line is emitted as its own
/// event; blank lines and other fields are ignored.
struct SSEParser {
  enum Event: Equatable {
    case data(String)
    case done
  }

  mutating func consume(line: String) -> Event? {
    guard line.hasPrefix("data:") else { return nil }
    var payload = String(line.dropFirst("data:".count))
    if payload.hasPrefix(" ") { payload.removeFirst() }
    if payload == "[DONE]" {
      return .done
    }
    return payload.isEmpty ? nil : .data(payload)
  }

}

// MARK: - Tool call assembly

struct AssistantToolCall: Equatable, Identifiable {
  let id: String
  let name: String
  let argumentsJSON: String
}

/// Accumulates streamed tool-call fragments from either provider dialect.
struct ToolCallAccumulator {
  private struct Partial {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
  }

  private var partials: [Int: Partial] = [:]

  mutating func openAIDelta(_ delta: [String: Any]) {
    guard let calls = delta["tool_calls"] as? [[String: Any]] else { return }
    for call in calls {
      let index = call["index"] as? Int ?? 0
      var partial = partials[index] ?? Partial()
      if let id = call["id"] as? String, !id.isEmpty { partial.id = id }
      if let function = call["function"] as? [String: Any] {
        if let name = function["name"] as? String, !name.isEmpty { partial.name += name }
        if let arguments = function["arguments"] as? String { partial.arguments += arguments }
      }
      partials[index] = partial
    }
  }

  mutating func claudeStart(index: Int, id: String, name: String) {
    var partial = partials[index] ?? Partial()
    partial.id = id
    partial.name = name
    partials[index] = partial
  }

  mutating func claudeArguments(index: Int, fragment: String) {
    var partial = partials[index] ?? Partial()
    partial.arguments += fragment
    partials[index] = partial
  }

  func finalize() -> [AssistantToolCall] {
    partials.keys.sorted().compactMap { index in
      let partial = partials[index]!
      guard !partial.name.isEmpty else { return nil }
      return AssistantToolCall(
        id: partial.id.isEmpty ? "call_\(index)" : partial.id,
        name: partial.name,
        argumentsJSON: partial.arguments.isEmpty ? "{}" : partial.arguments)
    }
  }
}

// MARK: - OpenAI-compatible provider

struct OpenAICompatibleProvider: AssistantProvider {
  let identifier = AssistantProviderKind.openAICompatible.rawValue
  var session: URLSession = .shared

  func stream(_ request: AssistantRequest,
              configuration: AssistantConfiguration) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(request, configuration: configuration)
          let (bytes, response) = try await session.bytes(for: urlRequest)
          try Self.validate(response)
          var parser = SSEParser()
          var accumulator = ToolCallAccumulator()
          var sawDone = false
          var providerError: AssistantError?

          /// - Returns: `true` when the stream reached its protocol terminal.
          func handle(_ event: SSEParser.Event) -> Bool {
            switch event {
            case .done:
              sawDone = true
              return true
            case .data(let payload):
              guard let data = payload.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                providerError = .malformedResponse
                return true
              }
              if let error = object["error"] as? [String: Any] {
                providerError = .provider(
                  error["message"] as? String ?? AssistantError.malformedResponse.errorDescription ?? "")
                return true
              }
              guard let choices = object["choices"] as? [[String: Any]],
                    let choice = choices.first else { return false }
              if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                  continuation.yield(.text(text))
                }
                accumulator.openAIDelta(delta)
              }
              // `finish_reason` is a terminal marker even when the server
              // closes without sending `[DONE]`.
              if choice["finish_reason"] is String {
                sawDone = true
              }
              return false
            }
          }

          readLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = parser.consume(line: line) {
              if handle(event) { break readLoop }
            }
          }
          if let providerError {
            continuation.finish(throwing: providerError)
            return
          }
          let calls = accumulator.finalize()
          // A clean close without a terminal marker leaves the answer's
          // completeness unknown, so it is a partial response, not success.
          guard sawDone else {
            continuation.finish(throwing: AssistantError.malformedResponse)
            return
          }
          if !calls.isEmpty {
            continuation.yield(.toolCalls(calls))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.map(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makeRequest(_ request: AssistantRequest,
                           configuration: AssistantConfiguration) throws -> URLRequest {
    guard let url = configuration.endpointURL else {
      throw AssistantError.invalidEndpoint
    }
    let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if configuration.requiresAPIKey, key?.isEmpty != false {
      throw AssistantError.missingAPIKey
    }

    let messages: [[String: Any]] = request.messages.map { message in
      var dictionary: [String: Any] = [
        "role": message.role.rawValue,
        "content": message.content,
      ]
      if !message.toolCalls.isEmpty {
        dictionary["tool_calls"] = message.toolCalls.map { call in
          [
            "id": call.id,
            "type": "function",
            "function": ["name": call.name, "arguments": call.argumentsJSON],
          ]
        }
      }
      if let toolCallID = message.toolCallID {
        dictionary["tool_call_id"] = toolCallID
      }
      return dictionary
    }

    var body: [String: Any] = [
      "model": configuration.model,
      "stream": true,
      "messages": messages,
    ]
    if !request.tools.isEmpty {
      body["tools"] = request.tools.map { tool in
        [
          "type": "function",
          "function": [
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters,
          ],
        ]
      }
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = Self.requestTimeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let key, !key.isEmpty {
      urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  static let requestTimeout: TimeInterval = 120

  static func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw AssistantError.malformedResponse
    }
    switch http.statusCode {
    case 200..<300: return
    case 401, 403: throw AssistantError.unauthorized
    default: throw AssistantError.httpStatus(http.statusCode)
    }
  }

  static func map(_ error: Error) -> AssistantError {
    if let error = error as? AssistantError { return error }
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

// MARK: - Claude provider

struct ClaudeProvider: AssistantProvider {
  let identifier = AssistantProviderKind.claude.rawValue
  var session: URLSession = .shared

  func stream(_ request: AssistantRequest,
              configuration: AssistantConfiguration) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(request, configuration: configuration)
          let (bytes, response) = try await session.bytes(for: urlRequest)
          try OpenAICompatibleProvider.validate(response)
          var parser = SSEParser()
          var accumulator = ToolCallAccumulator()
          var sawMessageStop = false
          var providerError: AssistantError?

          /// - Returns: `true` when the stream reached its protocol terminal.
          func handle(_ payload: String) -> Bool {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
              providerError = .malformedResponse
              return true
            }
            switch type {
            case "content_block_start":
              guard let index = object["index"] as? Int,
                    let block = object["content_block"] as? [String: Any],
                    block["type"] as? String == "tool_use",
                    let name = block["name"] as? String else { return false }
              let id = block["id"] as? String ?? ""
              accumulator.claudeStart(index: index, id: id, name: name)
              return false
            case "content_block_delta":
              guard let index = object["index"] as? Int,
                    let delta = object["delta"] as? [String: Any],
                    let deltaType = delta["type"] as? String else { return false }
              if deltaType == "text_delta", let text = delta["text"] as? String {
                continuation.yield(.text(text))
              } else if deltaType == "input_json_delta",
                        let fragment = delta["partial_json"] as? String {
                accumulator.claudeArguments(index: index, fragment: fragment)
              }
              return false
            case "message_stop":
              sawMessageStop = true
              return true
            case "error":
              let message = (object["error"] as? [String: Any])?["message"] as? String
              providerError = .provider(
                message ?? AssistantError.malformedResponse.errorDescription ?? "Assistant error")
              return true
            default:
              return false
            }
          }

          readLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = parser.consume(line: line), case .data(let payload) = event {
              if handle(payload) { break readLoop }
            }
          }
          if let providerError {
            continuation.finish(throwing: providerError)
            return
          }
          // Tool arguments and the answer are only complete at message_stop.
          guard sawMessageStop else {
            continuation.finish(throwing: AssistantError.malformedResponse)
            return
          }
          let calls = accumulator.finalize()
          if !calls.isEmpty {
            continuation.yield(.toolCalls(calls))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: OpenAICompatibleProvider.map(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makeRequest(_ request: AssistantRequest,
                           configuration: AssistantConfiguration) throws -> URLRequest {
    guard let url = configuration.endpointURL else {
      throw AssistantError.invalidEndpoint
    }
    let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if configuration.requiresAPIKey, key?.isEmpty != false {
      throw AssistantError.missingAPIKey
    }

    var systemParts: [String] = []
    var messages: [[String: Any]] = []
    for message in request.messages {
      switch message.role {
      case .system:
        systemParts.append(message.content)
      case .user:
        messages.append(["role": "user", "content": message.content])
      case .assistant:
        var content: [[String: Any]] = []
        if !message.content.isEmpty {
          content.append(["type": "text", "text": message.content])
        }
        for call in message.toolCalls {
          content.append([
            "type": "tool_use",
            "id": call.id,
            "name": call.name,
            "input": (try? JSONSerialization.jsonObject(
              with: Data(call.argumentsJSON.utf8))) ?? [:],
          ])
        }
        messages.append(["role": "assistant", "content": content])
      case .tool:
        messages.append([
          "role": "user",
          "content": [[
            "type": "tool_result",
            "tool_use_id": message.toolCallID ?? "",
            "content": message.content,
          ]],
        ])
      }
    }

    var body: [String: Any] = [
      "model": configuration.model,
      "max_tokens": 4096,
      "stream": true,
      "messages": messages,
    ]
    if !systemParts.isEmpty {
      body["system"] = systemParts.joined(separator: "\n\n")
    }
    if !request.tools.isEmpty {
      body["tools"] = request.tools.map { tool in
        [
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.parameters,
        ]
      }
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = OpenAICompatibleProvider.requestTimeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let key, !key.isEmpty {
      urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
    }
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }
}

// MARK: - Mock provider

/// A deterministic provider for tests and for exercising the inspector's
/// states without a network.
struct MockAssistantProvider: AssistantProvider {
  let identifier = "mock"
  var events: [AssistantStreamEvent] = [
    .text("This is a mock answer. "),
    .text("It ends at 00:42."),
  ]
  var failure: AssistantError?

  func stream(_ request: AssistantRequest,
              configuration: AssistantConfiguration) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      if let failure {
        continuation.finish(throwing: failure)
        return
      }
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

// MARK: - Service

/// Owns the one in-flight assistant request. Configuration is re-read for each
/// request so settings changes and a new key take effect immediately.
final class AssistantService {
  typealias ProviderFactory = (AssistantProviderKind) -> AssistantProvider

  private var task: Task<Void, Never>?
  private(set) var isStreaming = false
  private var generation = 0
  private let providerFactory: ProviderFactory

  init(providerFactory: @escaping ProviderFactory = AssistantService.defaultProviderFactory) {
    self.providerFactory = providerFactory
  }

  static func defaultProviderFactory(_ kind: AssistantProviderKind) -> AssistantProvider {
    switch kind {
    case .openAICompatible: return OpenAICompatibleProvider()
    case .claude: return ClaudeProvider()
    }
  }

  func stream(configuration: AssistantConfiguration = .load(),
              request: AssistantRequest,
              onEvent: @escaping (AssistantStreamEvent) -> Void,
              onError: @escaping (AssistantError) -> Void,
              onFinish: @escaping () -> Void) {
    cancel()
    generation += 1
    let current = generation
    let provider = providerFactory(configuration.provider)
    isStreaming = true
    let stream = provider.stream(request, configuration: configuration)
    task = Task {
      do {
        for try await event in stream {
          try Task.checkCancellation()
          await MainActor.run {
            guard self.generation == current else { return }
            onEvent(event)
          }
        }
        await MainActor.run {
          guard self.generation == current else { return }
          self.isStreaming = false
          onFinish()
        }
      } catch {
        let mapped = (error as? AssistantError) ?? OpenAICompatibleProvider.map(error)
        await MainActor.run {
          guard self.generation == current else { return }
          self.isStreaming = false
          onError(mapped)
        }
      }
    }
  }

  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    isStreaming = false
  }
}
