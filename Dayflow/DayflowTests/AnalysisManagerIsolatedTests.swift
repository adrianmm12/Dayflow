import GRDB
import XCTest

@testable import Dayflow

/// Isolated-storage construction tests for `AnalysisManager`.
///
/// Every manager is constructed with an isolated `StorageManager` rooted at a
/// unique temporary directory, so no test can read or mutate real Dayflow
/// data. No real LLM/provider execution occurs: every exercised path either
/// takes the empty-day early exit or the no-screenshots early exit inside
/// `queueLLMRequest`, both of which stop before the global `LLMService`
/// boundary (which still uses `StorageManager.shared` internally).
///
/// Deliberately NOT tested here: a non-empty batch with ≥5 minutes of
/// screenshots would cross into `LLMService.shared` and is not yet isolated.
final class AnalysisManagerIsolatedTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  // MARK: - Isolated storage helpers

  private func makeIsolatedStorage() -> StorageManager {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-analysis-storage-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// Inserts one `analysis_batches` row timestamped inside the 4 AM–4 AM
  /// window of the given calendar day (mirroring `fetchBatches(forDay:)`'s
  /// and `resetBatchStatuses(forDay:)`'s window), with no screenshots. Test-
  /// data arrangement only: it exercises no production behavior.
  @discardableResult
  private func insertBatch(
    in storage: StorageManager, day: String, status: String = "analyzed"
  ) throws -> Int64 {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: day))
    let midDay = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let startTs = Int(midDay.timeIntervalSince1970)

    return try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (?, ?, ?)",
        arguments: [startTs, startTs + 300, status])
      return db.lastInsertedRowID
    }
  }

  // MARK: - Construction

  /// Construction with isolated storage is side-effect-free: no analysis
  /// work is scheduled (no timer, no processing run), and the instance's
  /// in-flight bookkeeping starts empty and instance-owned.
  func testConstructionIsSideEffectFreeWithInjectedStorage() {
    let storage = makeIsolatedStorage()
    let managerA = AnalysisManager(storage: storage)
    let managerB = AnalysisManager(storage: makeIsolatedStorage())

    XCTAssertEqual(managerA.inFlightBatchCount, 0)
    XCTAssertFalse(managerA.isBatchInFlight(1))
    XCTAssertEqual(managerB.inFlightBatchCount, 0)
    // Nothing was scheduled against the injected database: no batches were
    // created by construction alone.
    XCTAssertTrue(storage.allBatches().isEmpty)
  }

  // MARK: - Reprocessing (storage-selection/reset portion, injected)

  /// An empty-day reprocess against injected storage completes successfully
  /// through the early exit: the deletion/reset phases read only the
  /// injected store (which stays empty) and no LLM work is queued.
  func testEmptyDayReprocessReadsOnlyInjectedStoreAndNeverReachesLLM() {
    let storage = makeIsolatedStorage()
    let manager = AnalysisManager(storage: storage)
    let emptyDay = "1900-01-01"
    let completed = expectation(description: "reprocessDay completion")
    var progressMessages: [String] = []

    manager.reprocessDay(
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
    XCTAssertTrue(storage.allBatches().isEmpty)
  }

  /// A day with a screenshot-less batch reprocesses entirely against the
  /// injected store: the batch is found, reset to pending, and then ends in
  /// the no-screenshots terminal state ("failed_empty") — the
  /// `queueLLMRequest` early exit that stops before any LLM call.
  func testReprocessDayResetsInjectedBatchWithoutScreenshotsAndSkipsLLM() throws {
    let storage = makeIsolatedStorage()
    let manager = AnalysisManager(storage: storage)
    let day = "2026-01-15"
    let batchID = try insertBatch(in: storage, day: day)
    XCTAssertEqual(storage.fetchBatches(forDay: day).first?.status, "analyzed")

    let completed = expectation(description: "reprocessDay completion")
    manager.reprocessDay(
      day,
      progressHandler: { _ in },
      completion: { result in
        if case .success = result {
        } else {
          XCTFail("Expected success, got: \(result)")
        }
        completed.fulfill()
      })

    wait(for: [completed], timeout: 20.0)

    let batches = storage.fetchBatches(forDay: day)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.id, batchID)
    XCTAssertEqual(batches.first?.status, "failed_empty")
  }

  /// Two managers rooted at separate isolated stores see only their own
  /// storage: a batch seeded into A is invisible to B's day reprocess, which
  /// takes the empty-day early exit against B's store.
  func testTwoManagersSeeOnlyTheirOwnInjectedStorage() throws {
    let day = "2026-01-15"
    let storageA = makeIsolatedStorage()
    try insertBatch(in: storageA, day: day)
    _ = AnalysisManager(storage: storageA)
    let storageB = makeIsolatedStorage()
    let managerB = AnalysisManager(storage: storageB)

    let completed = expectation(description: "reprocessDay completion")
    var progressMessages: [String] = []
    managerB.reprocessDay(
      day,
      progressHandler: { message in
        progressMessages.append(message)
      },
      completion: { result in
        if case .success = result {
        } else {
          XCTFail("Expected success, got: \(result)")
        }
        completed.fulfill()
      })

    wait(for: [completed], timeout: 10.0)
    XCTAssertTrue(
      progressMessages.contains(where: { $0.contains("No batches found for day \(day)") }),
      "Expected the empty-day progress message for B; got: \(progressMessages)")
    // B's store was queried, found empty, and left untouched — A's batch
    // never leaked into B's reprocess.
    XCTAssertTrue(storageB.allBatches().isEmpty)
    XCTAssertEqual(storageA.fetchBatches(forDay: day).count, 1)
  }

  // MARK: - Idle shortcut (fully injected, no LLM)

  /// Drives the complete idle-shortcut path deterministically without any
  /// LLM call: a batch whose screenshots are all idle (10 s apart, each
  /// reporting ≥60 s idle) spanning exactly 12 minutes — the classifier's
  /// minimum eligible duration. `queueLLMRequest` classifies it idle,
  /// persists an Idle card, writes the terminal "analyzed" status (with the
  /// idle-shortcut reason) and performs a passive checkpoint — every storage
  /// operation against the injected store, never production storage or
  /// `LLMService.shared`.
  func testIdleShortcutWritesTerminalStatusAndCheckpointToInjectedStore() throws {
    let storage = makeIsolatedStorage()
    let manager = AnalysisManager(storage: storage)
    let day = "2026-01-15"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: day))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let startTs = Int(noon.timeIntervalSince1970)

    // One batch (12-minute span) + 73 fully idle screenshots at 10 s
    // intervals. Test-data arrangement only.
    let batchID = try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (?, ?, 'analyzed')",
        arguments: [startTs, startTs + 720])
      let batchId = db.lastInsertedRowID
      for offset in stride(from: 0, through: 720, by: 10) {
        try db.execute(
          sql: """
            INSERT INTO screenshots(
              captured_at, file_path, file_size, idle_seconds_at_capture, frame_index, is_deleted)
            VALUES (?, ?, ?, ?, 0, 0)
          """,
          arguments: [startTs + offset, "/nonexistent/segment.mp4", 1_000, 60])
        try db.execute(
          sql: "INSERT INTO batch_screenshots(batch_id, screenshot_id) VALUES (?, ?)",
          arguments: [batchId, db.lastInsertedRowID])
      }
      return batchId
    }
    XCTAssertEqual(storage.screenshotsForBatch(batchID).count, 73)

    let completed = expectation(description: "reprocessDay completion")
    manager.reprocessDay(
      day,
      progressHandler: { _ in },
      completion: { result in
        if case .success = result {
        } else {
          XCTFail("Expected success, got: \(result)")
        }
        completed.fulfill()
      })

    wait(for: [completed], timeout: 20.0)

    // The terminal status and its idle-shortcut reason were written to the
    // injected database (synchronously, before completion was reported).
    let batches = storage.fetchBatches(forDay: day)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.id, batchID)
    XCTAssertEqual(batches.first?.status, "analyzed")
    let reason = try storage.db.read { db in
      try String.fetchOne(
        db, sql: "SELECT reason FROM analysis_batches WHERE id = ?", arguments: [batchID])
    }
    XCTAssertEqual(reason, "idle_shortcut_applied")

    // The idle card itself was persisted to the injected store as well.
    let cards = storage.fetchTimelineCards(forDay: day)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.title, "Idle")
    XCTAssertEqual(cards.first?.category, "Idle")
    XCTAssertEqual(cards.first?.batchId, batchID)
  }
}
