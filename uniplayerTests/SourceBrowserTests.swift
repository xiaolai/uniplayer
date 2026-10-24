//
//  SourceBrowserTests.swift
//  UniPlayerTests
//

import Foundation
import XCTest
@testable import UniPlayer

@MainActor
final class SourceBrowserTests: XCTestCase {

  private func makeModel() async throws -> (SourceBrowserModel, SourceCoordinator,
                                            ScriptedProvider, URL, MediaSourceRoot) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("uniplayer-browser-\(UUID().uuidString)", isDirectory: true)
    let sub = directory.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let provider = ScriptedProvider()
    provider.directories[directory.path] = [("Sub", true), ("A.mkv", false), ("B.mkv", false)]
    provider.directories[sub.path] = [("C.mkv", false)]
    let catalog = try MediaCatalog.inMemory()
    let coordinator = SourceCoordinator(
      catalog: catalog,
      executor: SourceIOExecutor(limits: SourceIOLimits(defaultTimeout: 1)),
      providerFactory: SourceProviderFactory { _ in provider })
    guard case .created(let root) = try await coordinator.addRoot(
      at: directory, inclusion: .indexed) else {
      throw MediaSourceError.unsupported
    }
    let model = SourceBrowserModel(rootID: root.id, coordinator: coordinator,
                                   catalog: catalog)
    await model.loadInitial()
    return (model, coordinator, provider, directory, root)
  }

  func testLoadShowsFoldersFirstAndBreadcrumbs() async throws {
    let (model, _, _, _, root) = try await makeModel()
    XCTAssertEqual(model.rows.count, 3)
    XCTAssertTrue(model.rows[0].isDirectory)
    XCTAssertEqual(model.rows[0].name, "Sub")
    XCTAssertEqual(model.breadcrumbs.map(\.title), [root.displayName])
    XCTAssertFalse(model.canGoBack)
  }

  func testNavigateBackForwardAndUp() async throws {
    let (model, _, _, _, _) = try await makeModel()
    await model.navigate(to: "Sub", parentID: model.snapshot?.directory.id)
    XCTAssertEqual(model.rows.map(\.name), ["C.mkv"])
    XCTAssertEqual(model.breadcrumbs.map(\.title).count, 2)
    XCTAssertTrue(model.canGoBack)
    XCTAssertTrue(model.canGoUp)

    await model.goBack()
    XCTAssertEqual(model.rows.count, 3)
    XCTAssertTrue(model.canGoForward)

    await model.goForward()
    XCTAssertEqual(model.rows.map(\.name), ["C.mkv"])

    await model.goUp()
    XCTAssertEqual(model.rows.count, 3)
  }

  func testBackRestoresTheSelection() async throws {
    let (model, _, _, _, _) = try await makeModel()
    let row = try XCTUnwrap(model.rows.first { $0.name == "A.mkv" })
    model.selectedIDs = [row.id]
    await model.navigate(to: "Sub", parentID: model.snapshot?.directory.id)
    XCTAssertTrue(model.selectedIDs.isEmpty)

    await model.goBack()
    XCTAssertEqual(model.selectedIDs, [row.id])
    XCTAssertEqual(model.scrollRowID, row.id)
  }

  func testSearchHasExplicitScopes() async throws {
    let (model, _, _, _, _) = try await makeModel()
    model.query = "A"
    await model.searchNow()
    XCTAssertEqual(model.rows.map(\.name), ["A.mkv"])

    // Visiting the subdirectory indexes C, so All Library can find it.
    await model.navigate(to: "Sub", parentID: model.snapshot?.directory.id)
    model.scope = .allLibrary
    model.query = "C"
    await model.searchNow()
    XCTAssertEqual(model.rows.map(\.name), ["C.mkv"])

    await model.goBack()
    model.clearSearch()
    XCTAssertEqual(model.rows.count, 3)
  }

  func testActivationReportsIntentWithoutPlayingInTheModel() async throws {
    let (model, _, _, _, _) = try await makeModel()
    var opened: (UUID, PlaybackIntent)?
    model.openMedia = { id, intent in opened = (id, intent) }
    let row = try XCTUnwrap(model.rows.first { $0.name == "A.mkv" })
    model.activate(row)
    XCTAssertEqual(opened?.0, row.id)
    XCTAssertEqual(opened?.1, .ordinaryOpen)
  }

  func testFavoriteActionUpdatesTheRow() async throws {
    let (model, _, _, _, _) = try await makeModel()
    let row = try XCTUnwrap(model.rows.first { $0.name == "A.mkv" })
    model.select(row)
    await model.toggleFavorite()
    let updated = model.rows.first { $0.id == row.id }
    XCTAssertEqual(updated?.isFavorite, true)
  }

  func testOfflineRefreshKeepsTheCachedListing() async throws {
    let (model, _, provider, directory, _) = try await makeModel()
    provider.errors[directory.path] = .offline
    await model.refresh()
    XCTAssertEqual(model.error, .offline)
    XCTAssertEqual(model.rows.count, 3)
    XCTAssertTrue(model.isStale)
  }

  func testMassAbsenceDuringVisitNeedsReview() async throws {
    let (model, _, provider, directory, _) = try await makeModel()
    provider.directories[directory.path] = []
    await model.refresh()
    let review = try XCTUnwrap(model.pendingReview)
    XCTAssertEqual(review.reason, "emptyRoot")
    XCTAssertEqual(model.rows.count, 3, "absence is not applied before review")
  }
}
