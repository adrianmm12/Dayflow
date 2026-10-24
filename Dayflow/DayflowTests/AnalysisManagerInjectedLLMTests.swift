import GRDB
import XCTest

@testable import Dayflow

/// Injected-LLM tests for `AnalysisManager`: a deterministic `LLMServicing`
/// fake plus isolated storage prove the manager's inference boundary —
/// batching geometry, batch routing, in-flight bookkeeping, completion
/// semantics, and reprocessing — without contacting any real provider or
/// production storage.
///
/// The fake deliberately does NOT reproduce the concrete `LLMService`'s
/// observation/card persistence (that responsibility lives on the service
/// side of the boundary, against ITS storage): it returns success with no
/// cards, so the manager-owned half (in-flight tracking, terminal batch
/// status, catch-up checks) is what these tests verify.
private struct FakeProviderError: Error {}

/// Deterministic `LLMServicing` test double.
///
/// - `processBatch` records every batch ID it is asked to process.
/// - In `holdsCompletions` mode it holds the completion until the test
///   releases it, so in-flight bookkeeping can be observed mid-request.
/// - Otherwise it completes immediately with `immediateResult`.
/// - `batchingConfig` defaults to `BatchingConfig.standard` (the exact
///   production geometry) so batch formation matches production rules.
/// - Text/chat generation traps: it is never used by `AnalysisManager`.
private final class FakeLLMService: LLMServicing, @unchecked Sendable {
  let batchingConfig: BatchingConfig

  private let lock = NSLock()
  private var recordedBatchIds: [Int64] = []
  private var heldCompletions: [(Result<ProcessedBatchResult, Error>) -> Void] = []

  private let holdsCompletions: Bool
  private let immediateResult: Result<ProcessedBatchResult, Error>

  init(
    batchingConfig: BatchingConfig = .standard,
    holdsCompletions: Bool = false,
    immediateResult: Result<ProcessedBatchResult, Error> = .success(
      ProcessedBatchResult(cards: [], cardIds: []))
  ) {
    self.batchingConfig = batchingConfig
    self.holdsCompletions = holdsCompletions
    self.immediateResult = immediateResult
  }

  /// Batch IDs `processBatch` was asked to process, in order.
  var processBatchBatchIds: [Int64] {
    lock.withLock { recordedBatchIds }
  }

  /// Completions currently held (one per unfinished `processBatch`).
  var heldCompletionCount: Int {
    lock.withLock { heldCompletions.count }
  }

  /// Releases every held completion with the given result.
  func releaseHeldCompletions(with result: Result<ProcessedBatchResult, Error>) {
    let toRelease: [(Result<ProcessedBatchResult, Error>) -> Void] = lock.withLock {
      let pending = heldCompletions
      heldCompletions = []
      return pending
    }
    toRelease.forEach { $0(result) }
  }

  func processBatch(
    _ batchId: Int64,
    progressHandler: ((LLMProcessingStep) -> Void)?,
    completion: @escaping (Result<ProcessedBatchResult, Error>) -> Void
  ) {
    lock.lock()
    recordedBatchIds.append(batchId)
    let shouldHold = holdsCompletions
    lock.unlock()

    if shouldHold {
      lock.lock()
      heldCompletions.append(completion)
      lock.unlock()
    } else {
      completion(immediateResult)
    }
  }
}

final class AnalysisManagerInjectedLLMTests: XCTestCase {
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
      .appendingPathComponent("dayflow-injected-llm-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// Inserts NOT-yet-batched (unprocessed) non-idle screenshots into the
  /// isolated store — the input for `triggerAnalysisNow()`'s batching pass.
  @discardableResult
  private func seedUnprocessedScreenshots(
    in storage: StorageManager, from startTs: Int, to endTs: Int, interval: Int
  ) throws -> Int {
    try storage.db.write { db in
      var count = 0
      for offset in stride(from: startTs, through: endTs, by: interval) {
        try db.execute(
          sql: """
            INSERT INTO screenshots(
              captured_at, file_path, file_size, idle_seconds_at_capture, frame_index, is_deleted)
            VALUES (?, ?, ?, ?, 0, 0)
          """,
          arguments: [offset, "/nonexistent/segment.mp4", 1_000, 0])
        count += 1
      }
      return count
    }
  }

  /// Inserts one batch (status "analyzed") plus fully joined non-idle
  /// screenshots spanning 12 minutes inside the day's 4 AM window — the
  /// input for `reprocessDay`'s non-idle path. Returns the batch ID.
  @discardableResult
  private func seedDayBatchWithNonIdleScreenshots(in storage: StorageManager, day: String) throws
    -> Int64
  {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: day))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let startTs = Int(noon.timeIntervalSince1970)

    return try storage.db.write { db in
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
          arguments: [startTs + offset, "/nonexistent/segment.mp4", 1_000, 0])
        try db.execute(
          sql: "INSERT INTO batch_screenshots(batch_id, screenshot_id) VALUES (?, ?)",
          arguments: [batchId, db.lastInsertedRowID])
      }
      return batchId
    }
  }

  /// Polls `condition` on a short interval until it holds or the deadline
  /// passes; returns the final evaluation.
  @discardableResult
  private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
  }

  private func batchStatus(in storage: StorageManager, batchId: Int64) -> String? {
    storage.allBatches().first { $0.id == batchId }?.status
  }

  // MARK: - Batching + routing through the injected fake

  /// Screenshots within the 24h lookback are batched using the FAKE's
  /// `batchingConfig` (production geometry), the batch is created in the
  /// injected store, and `queueLLMRequest` hands it to the injected fake —
  /// never `LLMService.shared`.
  func testTriggerAnalysisRoutesBatchThroughInjectedFakeAndTracksInFlight() throws {
    let storage = makeIsolatedStorage()
    let fake = FakeLLMService(holdsCompletions: true)
    let manager = AnalysisManager(storage: storage, llmService: fake)

    // 31 non-idle screenshots every 30 s across exactly 900 s (the
    // standard target duration): one bucket, one kept batch.
    let now = Int(Date().timeIntervalSince1970)
    try seedUnprocessedScreenshots(in: storage, from: now - 900, to: now, interval: 30)

    manager.triggerAnalysisNow()

    XCTAssertTrue(waitUntil { fake.processBatchBatchIds.count == 1 })
    let batchId = try XCTUnwrap(fake.processBatchBatchIds.first)
    // Batch/screenshot selection came from the injected store: the batch
    // exists there with all 31 screenshots joined to it.
    XCTAssertEqual(storage.screenshotsForBatch(batchId).count, 31)

    // Request held open by the fake: exactly this batch is in flight...
    XCTAssertEqual(manager.inFlightBatchCount, 1)
    XCTAssertTrue(manager.isBatchInFlight(batchId))
    // ...and the manager's persisted "processing" status landed in the
    // injected store before the request started.
    XCTAssertTrue(waitUntil { batchStatus(in: storage, batchId: batchId) == "processing" })

    fake.releaseHeldCompletions(
      with: .success(ProcessedBatchResult(cards: [], cardIds: [])))

    // Completion fired: in-flight drops to zero and the manager's terminal
    // "completed" status lands in the injected store.
    XCTAssertTrue(waitUntil { manager.inFlightBatchCount == 0 })
    XCTAssertFalse(manager.isBatchInFlight(batchId))
    XCTAssertTrue(waitUntil { batchStatus(in: storage, batchId: batchId) == "completed" })
    // No further LLM work was requested (catch-up found nothing failed).
    XCTAssertEqual(fake.processBatchBatchIds.count, 1)
  }

  /// A fake provider failure marks the batch failed in the injected store,
  /// following the manager's existing failure semantics.
  func testFakeProviderFailureMarksBatchFailedInInjectedStore() throws {
    let storage = makeIsolatedStorage()
    let fake = FakeLLMService(immediateResult: .failure(FakeProviderError()))
    let manager = AnalysisManager(storage: storage, llmService: fake)

    let now = Int(Date().timeIntervalSince1970)
    try seedUnprocessedScreenshots(in: storage, from: now - 900, to: now, interval: 30)

    manager.triggerAnalysisNow()

    XCTAssertTrue(waitUntil { fake.processBatchBatchIds.count == 1 })
    let batchId = try XCTUnwrap(fake.processBatchBatchIds.first)
    XCTAssertTrue(waitUntil { batchStatus(in: storage, batchId: batchId) == "failed" })
    XCTAssertEqual(manager.inFlightBatchCount, 0)
  }

  /// Two managers wired to distinct fakes and distinct isolated stores route
  /// their batches independently: A's trigger never reaches B's fake.
  func testTwoManagersUseDistinctFakeLLMsIndependently() throws {
    let storageA = makeIsolatedStorage()
    let storageB = makeIsolatedStorage()
    let fakeA = FakeLLMService()
    let fakeB = FakeLLMService(holdsCompletions: true)
    let managerA = AnalysisManager(storage: storageA, llmService: fakeA)
    let managerB = AnalysisManager(storage: storageB, llmService: fakeB)

    let now = Int(Date().timeIntervalSince1970)
    try seedUnprocessedScreenshots(in: storageA, from: now - 900, to: now, interval: 30)
    try seedUnprocessedScreenshots(in: storageB, from: now - 900, to: now, interval: 30)

    managerA.triggerAnalysisNow()
    XCTAssertTrue(waitUntil { fakeA.processBatchBatchIds.count == 1 })
    XCTAssertEqual(fakeB.processBatchBatchIds.count, 0)

    managerB.triggerAnalysisNow()
    XCTAssertTrue(waitUntil { fakeB.processBatchBatchIds.count == 1 })
    XCTAssertEqual(fakeA.processBatchBatchIds.count, 1)

    fakeB.releaseHeldCompletions(
      with: .success(ProcessedBatchResult(cards: [], cardIds: [])))
    XCTAssertTrue(waitUntil { managerB.inFlightBatchCount == 0 })
    XCTAssertEqual(managerA.inFlightBatchCount, 0)
  }

  // MARK: - Reprocessing through the injected fake (non-idle path)

  /// A non-idle day reprocess runs entirely on injected dependencies: the
  /// day's batch is reset in the injected store, handed to the injected
  /// fake (never `LLMService.shared`), and the manager's terminal
  /// "completed" status lands back in the injected store.
  func testReprocessDayDrivesNonIdleBatchThroughInjectedFakeLLM() throws {
    let storage = makeIsolatedStorage()
    let fake = FakeLLMService()
    let manager = AnalysisManager(storage: storage, llmService: fake)
    let day = "2026-01-15"
    let batchID = try seedDayBatchWithNonIdleScreenshots(in: storage, day: day)

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

    XCTAssertEqual(fake.processBatchBatchIds, [batchID])
    let batches = storage.fetchBatches(forDay: day)
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.status, "completed")
  }
}
