//
//  AddSourceFlowTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class AddSourceFlowTests: XCTestCase {

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-add-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func coordinator(provider: ScriptedProvider) throws -> SourceCoordinator {
    SourceCoordinator(
      catalog: try MediaCatalog.inMemory(),
      executor: SourceIOExecutor(limits: SourceIOLimits(defaultTimeout: 1)),
      providerFactory: SourceProviderFactory { _ in provider })
  }

  func testDuplicateAndOverlapOutcomes() async throws {
    let directory = try makeDirectory()
    let child = directory.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let provider = ScriptedProvider()
    let coordinator = try coordinator(provider: provider)

    guard case .created = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected created")
    }
    guard case .existing = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected existing")
    }
    guard case .overlap = try await coordinator.addRoot(at: child) else {
      return XCTFail("expected overlap")
    }
  }

  func testDetachedSourceOffersRestore() async throws {
    let directory = try makeDirectory()
    let provider = ScriptedProvider()
    let coordinator = try coordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected created")
    }
    try await coordinator.remove(root)
    guard case .restore = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected restore")
    }
  }

  func testPossibleAliasNeedsExplicitDuplicateConsent() async throws {
    let directory = try makeDirectory()
    let provider = ScriptedProvider()
    let coordinator = try coordinator(provider: provider)
    guard case .created = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected created")
    }

    provider.namespace = SourceNamespace(
      kind: .local, volumeIdentity: "different-volume", fileSystemType: "smbfs",
      endpointLabel: "Scripted", accountContextLabel: nil)
    guard case .possibleAlias = try await coordinator.addRoot(at: directory) else {
      return XCTFail("expected possible alias")
    }
    guard case .created = try await coordinator.addRoot(
      at: directory, allowPossibleAliasDuplicate: true) else {
      return XCTFail("expected explicit duplicate creation")
    }
    XCTAssertEqual(coordinator.roots.count, 2)
  }

  func testUnknownIdentityIsStillBrowsable() async throws {
    let directory = try makeDirectory()
    let provider = ScriptedProvider()
    provider.forceUnverified = true
    provider.directories[directory.path] = [("A.mkv", false)]
    let coordinator = try coordinator(provider: provider)
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      return XCTFail("expected created")
    }
    let result = try await coordinator.scan(rootID: root.id)
    XCTAssertEqual(result.discovered, 1)
  }
}
