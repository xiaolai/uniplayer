//
//  SaySoTranslationTests.swift
//  UniPlayerTests
//

import Foundation
import SaySoAI
import XCTest
@testable import UniPlayer

final class AssistantProfileTests: XCTestCase {

  func testFullEndpointNormalizesToTheDocumentedBase() {
    XCTAssertEqual(
      AssistantProfiles.baseURL("http://127.0.0.1:11434/v1/chat/completions")?.absoluteString,
      "http://127.0.0.1:11434/v1")
    XCTAssertEqual(
      AssistantProfiles.baseURL("https://api.openai.com/v1/chat/completions/")?.absoluteString,
      "https://api.openai.com/v1")
  }

  func testKnownEndpointDerivesItsProfile() {
    XCTAssertEqual(
      AssistantProfiles.derivedID(for: "http://127.0.0.1:11434/v1/chat/completions"),
      "ollama")
    XCTAssertEqual(
      AssistantProfiles.derivedID(for: "https://api.openai.com/v1"),
      "openai")
    XCTAssertEqual(
      AssistantProfiles.derivedID(for: "https://example.com/v1"),
      AssistantProfiles.customID)
  }

  func testProfileSuppliesRequestURLAndAuthorization() throws {
    let configuration = AssistantConfiguration(
      provider: .openAICompatible,
      profileID: "openai",
      endpoint: "https://api.openai.com/v1",
      model: "gpt-5.4",
      apiKey: "secret")
    XCTAssertEqual(configuration.openAIRequestURL?.absoluteString,
                   "https://api.openai.com/v1/chat/completions")
    XCTAssertTrue(configuration.requiresAPIKey)
    XCTAssertTrue(configuration.isConfigured)
    var request = URLRequest(url: configuration.openAIRequestURL!)
    configuration.applyAuthorization(to: &request)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertFalse(configuration.redacting("the key secret is here").contains("secret"))
  }

  func testLoopbackCustomEndpointNeedsNoKey() {
    let configuration = AssistantConfiguration(
      provider: .openAICompatible,
      endpoint: "http://127.0.0.1:8080/v1/chat/completions",
      model: "local",
      apiKey: nil)
    XCTAssertFalse(configuration.requiresAPIKey)
    XCTAssertTrue(configuration.isConfigured)
  }

  func testOldFullEndpointDerivesTheProfileOnLoad() {
    let oldEndpoint = Preference.string(for: .assistantEndpoint)
    let oldProfile = Preference.string(for: .assistantProfile)
    defer {
      Preference.set(oldEndpoint ?? "", for: .assistantEndpoint)
      if let oldProfile {
        Preference.set(oldProfile, for: .assistantProfile)
      } else {
        UserDefaults.standard.removeObject(forKey: Preference.Key.assistantProfile.rawValue)
      }
    }
    Preference.set("http://127.0.0.1:11434/v1/chat/completions", for: .assistantEndpoint)
    UserDefaults.standard.removeObject(forKey: Preference.Key.assistantProfile.rawValue)
    XCTAssertEqual(AssistantConfiguration.load().profileID, "ollama")
  }

  func testClaudeKeepsItsNativeMessagesEndpoint() {
    let configuration = AssistantConfiguration(
      provider: .claude,
      endpoint: "https://api.anthropic.com/v1/messages",
      model: "claude-sonnet-5-5",
      apiKey: "secret")
    XCTAssertEqual(configuration.endpointURL?.absoluteString,
                   "https://api.anthropic.com/v1/messages")
    XCTAssertNil(configuration.catalogRequest)
    XCTAssertTrue(configuration.requiresAPIKey)
  }
}

final class AssistantOriginTests: XCTestCase {

  func testDefaultPortsCompareEqual() {
    let explicit = AssistantOrigin(URL(string: "https://example.com:443/v1")!)
    let implicit = AssistantOrigin(URL(string: "https://example.com/other")!)
    XCTAssertEqual(explicit, implicit)
  }

  func testSchemeHostAndPortMustMatch() {
    let origin = AssistantOrigin(URL(string: "https://example.com/v1")!)
    XCTAssertNotEqual(origin, AssistantOrigin(URL(string: "http://example.com/v1")!))
    XCTAssertNotEqual(origin, AssistantOrigin(URL(string: "https://other.example/v1")!))
    XCTAssertNotEqual(origin, AssistantOrigin(URL(string: "https://example.com:8443/v1")!))
  }

  func testFileURLHasNoOrigin() {
    XCTAssertNil(AssistantOrigin(URL(fileURLWithPath: "/tmp/file")))
  }
}

final class TranslationPromptTests: XCTestCase {

  func testSchemaIsValidJSONAndNamesTranslations() throws {
    let data = try XCTUnwrap(TranslationPrompt.answerSchema.data(using: .utf8))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(object["properties"])
    let properties = try XCTUnwrap(object["properties"] as? [String: Any])
    XCTAssertNotNil(properties["translations"])
  }

  func testQuestionCarriesBothParts() {
    let question = TranslationPrompt.question(
      system: "Translate into French.", user: #"{"lines":[{"id":1,"text":"Hello"}]}"#)
    XCTAssertTrue(question.contains("Translate into French."))
    XCTAssertTrue(question.contains("Hello"))
  }

  func testSourceCapabilities() {
    XCTAssertTrue(TranslationSource.assistant.supportsLive)
    XCTAssertTrue(TranslationSource.appleOnDevice.supportsLive)
    XCTAssertFalse(TranslationSource.codexCLI.supportsLive)
    XCTAssertFalse(TranslationSource.claudeCLI.supportsLive)
  }

  func testCLISelectionFallsBackToTheAssistantForLiveCaptions() {
    let previous = Preference.string(for: .translationSource)
    defer { Preference.set(previous ?? "", for: .translationSource) }
    Preference.set(TranslationSource.codexCLI.rawValue, for: .translationSource)
    XCTAssertEqual(TranslationSettings.liveSource, .assistant)
  }

  func testConfigurationErrorsAreSettingsCorrections() {
    let error = SaySoTranslation.assistantError(.notInstalled, source: .codexCLI)
    guard case .providerConfiguration = error else {
      XCTFail("a missing CLI must be a configuration error")
      return
    }
    XCTAssertTrue(error.needsSettingsCorrection)
  }

  func testAppleAvailabilityIsWorded() {
    for availability in AppleAvailability.fixedCases {
      XCTAssertFalse(SaySoTranslation.appleAvailabilityText(availability).isEmpty,
                     "\(availability) must have a sentence")
    }
  }
}

final class AssistantTextClientTests: XCTestCase {

  func testLiveClientUsesTheOneShotSource() async throws {
    let client = AssistantTextClient(
      source: { .appleOnDevice },
      oneShotAnswer: { source, system, user in
        XCTAssertEqual(source, .appleOnDevice)
        XCTAssertEqual(system, "system")
        XCTAssertEqual(user, "hello")
        return "bonjour"
      })
    let result = try await client.complete(system: "system", user: "hello")
    XCTAssertEqual(result, "bonjour")
  }
}

final class SettingsPageAssistantTests: XCTestCase {

  func testPageBuildsWithTranslationSourceControls() {
    let previous = Preference.string(for: .translationSource)
    defer {
      Preference.set(previous ?? TranslationSource.assistant.rawValue,
                     for: .translationSource)
    }
    Preference.set(TranslationSource.assistant.rawValue, for: .translationSource)
    let page = SettingsPageAssistant()
    let view = page.getView()
    XCTAssertFalse(view.subviews.isEmpty)
    XCTAssertFalse(page.builtSections.isEmpty)
    XCTAssertEqual(page.title, "AI Assistant")
  }

  func testPageBuildsWithTheOnDeviceSourceSelected() {
    let previous = Preference.string(for: .translationSource)
    defer {
      Preference.set(previous ?? TranslationSource.assistant.rawValue,
                     for: .translationSource)
    }
    Preference.set(TranslationSource.appleOnDevice.rawValue, for: .translationSource)
    let page = SettingsPageAssistant()
    let view = page.getView()
    XCTAssertFalse(view.subviews.isEmpty)
    XCTAssertFalse(page.builtSections.isEmpty)
  }
}
