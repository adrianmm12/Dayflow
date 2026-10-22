import GRDB
import XCTest

@testable import Dayflow

/// Analysis-injection tests for the `MacActivityEngine` façade: an injected
/// `AnalysisManaging` fake (or a real `AnalysisManager` wired to isolated
/// storage) proves the engine's analysis-facing behavior — scheduler startup,
/// day reprocessing, and the in-flight half of `processingStatus()` — no
/// longer consults the global `AnalysisManager` when dependencies are
/// injected. No test starts real recurring scheduling, real LLM work, or
/// touches production storage.
private final class FakeAnalysisManager: AnalysisManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var _reprocessedDays: [String] = []
  private var _startAnalysisJobCallCount = 0

  /// Read-only, controllable in-flight snapshot served to `processingStatus()`.
  let inFlightBatchCount: Int

  init(inFlightBatchCount: Int = 0) {
    self.inFlightBatchCount = inFlightBatchCount
  }

  var reprocessedDays: [String] {
    lock.withLock { _reprocessedDays }
  }

  var startAnalysisJobCallCount: Int {
    lock.withLock { _startAnalysisJobCallCount }
  }

  func startAnalysisJob() {
    lock.withLock { _startAnalysisJobCallCount += 1 }
  }

  func stopAnalysisJob() { fatalError("unexpected call") }
  func triggerAnalysisNow() { fatalError("unexpected call") }

  func reprocessDay(
    _ day: String,
    progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    lock.withLock { _reprocessedDays.append(day) }
    // Mirror the real manager's main-thread delivery semantics.
    DispatchQueue.main.async {
      progressHandler("fake: reprocessed \(day)")
      completion(.success(()))
    }
  }

  func reprocessSpecificBatches(
    _ batchIds: [Int64], progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    fatalError("unexpected call")
  }

  func reprocessBatch(
    _ batchId: Int64, stepHandler: @escaping (LLMProcessingStep) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    fatalError("unexpected call")
  }
}

@MainActor
final class MacActivityEngineAnalysisInjectionTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  private func makeIsolatedStorage() -> StorageManager {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-engine-analysis-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// Polls `condition` while servicing the main run loop (so main-queue
  /// delayed work — e.g. `startAnalysisJob()`'s 2 s startup delay — can fire
  /// while we wait). Returns the final evaluation.
  @discardableResult
  private func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
  }

  // MARK: - Reprocessing delegation

  /// `reprocessDay(...)` delegates to the injected analysis dependency, not
  /// the shared manager, and a second engine's fake is never consulted.
  func testReprocessDayDelegatesToInjectedAnalysis() {
    let fakeA = FakeAnalysisManager()
    let engineA = MacActivityEngine(storage: makeIsolatedStorage(), analysis: fakeA)
    let fakeB = FakeAnalysisManager()
    _ = MacActivityEngine(storage: makeIsolatedStorage(), analysis: fakeB)

    let completed = expectation(description: "reprocessDay completion")
    engineA.reprocessDay(
      "2026-01-15",
      progressHandler: { _ in },
      completion: { result in
        if case .success = result {
        } else {
          XCTFail("Expected success, got: \(result)")
        }
        completed.fulfill()
      })

    wait(for: [completed], timeout: 5.0)
    XCTAssertEqual(fakeA.reprocessedDays, ["2026-01-15"])
    XCTAssertEqual(fakeB.reprocessedDays, [])
  }

  // MARK: - Processing status sources

  /// `processingStatus()` combines persisted counts from the injected
  /// storage with the in-flight count from the injected analysis: a coherent
  /// pair, no global `AnalysisManager` consult.
  func testProcessingStatusCombinesInjectedStorageAndInjectedAnalysis() throws {
    let storage = makeIsolatedStorage()
    try storage.db.write { db in
      for status in ["analyzed", "completed", "pending", "failed"] {
        try db.execute(
          sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, ?)",
          arguments: [status])
      }
    }
    let engine = MacActivityEngine(storage: storage, analysis: FakeAnalysisManager(inFlightBatchCount: 2))

    let status = engine.processingStatus()

    XCTAssertEqual(status.analyzedBatchCount, 2)
    XCTAssertEqual(status.pendingBatchCount, 1)
    XCTAssertEqual(status.failedBatchCount, 1)
    XCTAssertEqual(status.inFlightBatchCount, 2)
    XCTAssertTrue(status.isAnalyzing)
  }

  /// A second engine with a different fake reads its own in-flight state;
  /// dependencies never cross.
  func testTwoEnginesUseDistinctInjectedAnalysisDependencies() throws {
    let storageA = makeIsolatedStorage()
    try storageA.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, 'pending')"
      )
    }
    let engineA = MacActivityEngine(
      storage: storageA, analysis: FakeAnalysisManager(inFlightBatchCount: 1))
    let engineB = MacActivityEngine(
      storage: makeIsolatedStorage(), analysis: FakeAnalysisManager(inFlightBatchCount: 0))

    let statusA = engineA.processingStatus()
    let statusB = engineB.processingStatus()

    XCTAssertEqual(statusA.inFlightBatchCount, 1)
    XCTAssertTrue(statusA.isAnalyzing)
    XCTAssertEqual(statusA.pendingBatchCount, 1)

    XCTAssertEqual(statusB.inFlightBatchCount, 0)
    XCTAssertFalse(statusB.isAnalyzing)
    XCTAssertEqual(statusB.pendingBatchCount, 0)
  }

  // MARK: - Scheduler startup delegation

  /// `startAnalysisJob()` routes to the injected analysis dependency after
  /// the existing 2-second startup delay. The fake records the call without
  /// starting any real recurring scheduling.
  func testStartAnalysisJobDelegatesToInjectedAnalysis() {
    let fake = FakeAnalysisManager()
    let engine = MacActivityEngine(storage: makeIsolatedStorage(), analysis: fake)

    engine.startAnalysisJob()

    XCTAssertTrue(
      waitUntil { fake.startAnalysisJobCallCount == 1 },
      "Expected the injected analysis's scheduler start after the 2 s delay")
    XCTAssertEqual(fake.startAnalysisJobCallCount, 1)
  }

  // MARK: - Façade composition (integration-style)

  /// Composing the engine with isolated storage AND a real `AnalysisManager`
  /// wired to that same storage keeps the façade coherent: a screenshot-less
  /// day batch seeded in the isolated store is found, reset, and ended in
  /// the no-screenshots terminal state entirely through the injected pair —
  /// the production database is never involved (the batch exists only in the
  /// injected store).
  func testFaçadeComposesIsolatedStorageWithIsolatedAnalysisEndToEnd() throws {
    let storage = makeIsolatedStorage()
    let analysis = AnalysisManager(storage: storage)
    let engine = MacActivityEngine(storage: storage, analysis: analysis)

    let day = "2026-01-15"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: day))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let startTs = Int(noon.timeIntervalSince1970)
    _ = try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (?, ?, 'analyzed')",
        arguments: [startTs, startTs + 300])
      return db.lastInsertedRowID
    }

    let completed = expectation(description: "reprocessDay completion")
    engine.reprocessDay(
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
    XCTAssertEqual(batches.first?.status, "failed_empty")
  }

  // MARK: - Shutdown routing

  /// `shutdown()` flushes the engine's injected storage — never the
  /// production database (impossible by construction: the engine only holds
  /// its injected dependency). Verified with the isolated concrete store:
  /// after a write, the truncate checkpoint must reset the isolated
  /// database's WAL to zero length.
  ///
  /// Note on the oracle: file sizes are read with the raw `stat` syscall
  /// because `URL.resourceValues(forKeys:)` caches values per URL instance
  /// and would report the stale pre-checkpoint size.
  func testShutdownTruncateCheckpointsInjectedStorage() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage, analysis: FakeAnalysisManager())
    let walPath = storage.dbURL.path + "-wal"

    // Force write-ahead-log content in the isolated database.
    try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, 'pending')"
      )
    }
    func walSize() -> Int {
      var s = stat()
      return stat(walPath, &s) == 0 ? Int(s.st_size) : -1
    }
    XCTAssertGreaterThanOrEqual(walSize(), 0, "expected the isolated WAL file to exist")

    engine.shutdown()

    // The truncate checkpoint merged the WAL into the isolated database and
    // reset the WAL to zero length.
    XCTAssertEqual(walSize(), 0)
  }
}
