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

  /// Exercises the reprocessDay delegation end to end against a day that
  /// cannot have any recorded data (long before Dayflow existed): no real
  /// cards are deleted, no batches are reset, and no LLM work is queued —
  /// the machinery takes its empty-day early exit.
  ///
  /// Destructive real-day reprocessing is intentionally NOT tested here.
  func testReprocessDayDelegatesToAnalysisForAnEmptyDay() {
    let engine = MacActivityEngine()
    let emptyDay = "1900-01-01"
    let completed = expectation(description: "reprocessDay completion")
    var progressMessages: [String] = []

    engine.reprocessDay(
      emptyDay,
      progressHandler: { message in
        progressMessages.append(message)
      },
      completion: { result in
        if case .success = result {
        } else {
          XCTFail("Expected success for an empty day, got: \(result)")
        }
        completed.fulfill()
      })

    wait(for: [completed], timeout: 10.0)
    XCTAssertTrue(
      progressMessages.contains(where: { $0.contains("No batches found for day \(emptyDay)") }),
      "Expected the empty-day progress message; got: \(progressMessages)")
  }

  // MARK: - Processing status

  func testSuccessStatusNormalization() {
    // The two terminal-success spellings (provider pipeline writes
    // "analyzed"; the analysis completion handler writes "completed").
    XCTAssertTrue(ActivityProcessingStatus.isSuccessStatus("analyzed"))
    XCTAssertTrue(ActivityProcessingStatus.isSuccessStatus("completed"))

    // Non-success statuses, including the terminal no-output outcomes.
    XCTAssertFalse(ActivityProcessingStatus.isSuccessStatus("pending"))
    XCTAssertFalse(ActivityProcessingStatus.isSuccessStatus("processing"))
    XCTAssertFalse(ActivityProcessingStatus.isSuccessStatus("failed"))
    XCTAssertFalse(ActivityProcessingStatus.isSuccessStatus("failed_empty"))
    XCTAssertFalse(ActivityProcessingStatus.isSuccessStatus("skipped_short"))
  }

  func testProcessingStatusMatchesPersistedBatchStatuses() {
    let engine = MacActivityEngine()
    let batches = StorageManager.shared.allBatches()

    let status = engine.processingStatus()

    XCTAssertEqual(
      status.analyzedBatchCount,
      batches.filter { ActivityProcessingStatus.isSuccessStatus($0.status) }.count)
    XCTAssertEqual(status.pendingBatchCount, batches.filter { $0.status == "pending" }.count)
    XCTAssertEqual(status.failedBatchCount, batches.filter { $0.status == "failed" }.count)
  }

  func testProcessingStatusSnapshotIsSane() {
    let engine = MacActivityEngine()

    let status = engine.processingStatus()

    XCTAssertGreaterThanOrEqual(status.analyzedBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.pendingBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.inFlightBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.failedBatchCount, 0)
    XCTAssertEqual(status.isAnalyzing, status.inFlightBatchCount > 0)
    // In-flight batches are executing now, so they cannot be idle-negative;
    // the tracker is the authoritative "now" signal.
    let batches = StorageManager.shared.allBatches()
    XCTAssertLessThanOrEqual(
      status.pendingBatchCount + status.failedBatchCount + status.analyzedBatchCount,
      batches.count)
  }
}
