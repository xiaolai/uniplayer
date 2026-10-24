//
//  MediaRelinkTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class MediaRelinkTests: XCTestCase {

  private func makeCoordinator() async throws -> (SourceCoordinator, ScriptedProvider,
                                                  URL, MediaSourceRoot) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-relink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("A.mkv", false), ("B.mkv", false)]
    let catalog = try MediaCatalog.inMemory()
    let coordinator = SourceCoordinator(
      catalog: catalog,
      executor: SourceIOExecutor(limits: SourceIOLimits(defaultTimeout: 1)),
      providerFactory: SourceProviderFactory { _ in provider })
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      throw MediaSourceError.unsupported
    }
    _ = try await coordinator.scan(rootID: root.id)
    return (coordinator, provider, directory, root)
  }

  func testNoCollisionRelinkKeepsIDAndUpdatesLocator() async throws {
    let (coordinator, _, directory, _) = try await makeCoordinator()
    let items = try await coordinator.catalog.libraryMedia()
    let a = try XCTUnwrap(items.first { $0.name == "A.mkv" })
    let newURL = directory.appendingPathComponent("Moved.mkv")
    let id = try await coordinator.relink(mediaID: a.id, to: newURL)
    XCTAssertEqual(id, a.id)
    let updated = try await coordinator.catalog.media(id: a.id)
    XCTAssertEqual(updated?.relativePath, "Moved.mkv")
  }

  func testCollisionNeedsConfirmationThenMerges() async throws {
    let (coordinator, _, directory, _) = try await makeCoordinator()
    let items = try await coordinator.catalog.libraryMedia()
    let a = try XCTUnwrap(items.first { $0.name == "A.mkv" })
    let b = try XCTUnwrap(items.first { $0.name == "B.mkv" })

    do {
      _ = try await coordinator.relink(mediaID: a.id,
                                       to: directory.appendingPathComponent("B.mkv"))
      XCTFail("expected confirmation requirement")
    } catch {
      guard case .possibleAlias(let existing) = (error as? MediaSourceError) else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(existing, b.id)
    }
    let merged = try await coordinator.relink(
      mediaID: a.id, to: directory.appendingPathComponent("B.mkv"),
      confirmMerge: true)
    XCTAssertTrue(merged == a.id || merged == b.id)
    let remaining = try await coordinator.catalog.libraryMedia()
    XCTAssertEqual(remaining.count, 1)
  }
}
