import XCTest

@testable import Dayflow

/// Read-only façade tests for MacActivityEngine's timeline activity access.
/// Reads go to the shared storage database (the same database the hosted
/// test app already reads); no lifecycle methods are invoked, so no capture
/// is started and nothing is written.
@MainActor
final class MacActivityEngineTests: XCTestCase {
  func testActivitiesDelegatesToStorageRangeQuery() {
    let engine = MacActivityEngine()
    let from = Date().addingTimeInterval(-90 * 24 * 60 * 60)
    let to = Date().addingTimeInterval(60)

    let viaEngine = engine.activities(from: from, to: to)
    let viaStorage = StorageManager.shared.fetchTimelineCardsByTimeRange(from: from, to: to)

    XCTAssertEqual(viaEngine.count, viaStorage.count)
    XCTAssertEqual(viaEngine.map(\.recordId), viaStorage.map(\.recordId))
    XCTAssertEqual(viaEngine.map(\.title), viaStorage.map(\.title))
    XCTAssertEqual(viaEngine.map(\.startTimestamp), viaStorage.map(\.startTimestamp))
  }

  func testActivitiesReturnsNoCardsForAFutureRange() {
    let engine = MacActivityEngine()
    let future = Date().addingTimeInterval(24 * 60 * 60)

    let cards = engine.activities(from: future, to: future.addingTimeInterval(60))

    XCTAssertTrue(cards.isEmpty)
  }

  func testActivitiesDoesNotRequireEngineLifecycle() {
    // The read path must work on a freshly constructed engine (headless use:
    // no start(), no recorder, no analysis job).
    let engine = MacActivityEngine()

    let cards = engine.activities(from: .distantPast, to: .distantFuture)

    XCTAssertEqual(cards.count, StorageManager.shared.fetchTimelineCardsByTimeRange(
      from: .distantPast, to: .distantFuture).count)
  }
}
