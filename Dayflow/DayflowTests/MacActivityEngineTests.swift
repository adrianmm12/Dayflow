import GRDB
import XCTest

@testable import Dayflow

/// Façade tests for MacActivityEngine's timeline activity access and
/// processing status, using isolated storage instances (`StorageManager(isolatedAt:)`)
/// rooted at unique temporary directories. `StorageManager.shared` is never
/// constructed or compared against here, so no test can read or mutate real
/// Dayflow data.
///
/// Lifecycle methods are not invoked, so no capture is started and nothing
/// beyond the isolated databases is written.
///
/// Known limitation pinned by these tests: `reprocessDay(...)` still
/// delegates to `AnalysisManager.shared` (global storage), and
/// `processingStatus()`'s in-flight count still reads the shared
/// `AnalysisManager`'s in-memory tracker — neither is storage-injected yet.
@MainActor
final class MacActivityEngineTests: XCTestCase {
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
      .appendingPathComponent("dayflow-engine-storage-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// Inserts one timeline card directly into the isolated database with the
  /// given unix-timestamp range. Test-data arrangement only: it does not go
  /// through a storage API, so it exercises no production behavior.
  @discardableResult
  private func insertTimelineCard(
    in storage: StorageManager, title: String, startTs: Int, endTs: Int
  ) throws -> Int64 {
    try storage.db.write { db in
      try db.execute(
        sql: """
          INSERT INTO timeline_cards(start, end, start_ts, end_ts, day, title, summary, category)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: ["9:00 AM", "9:05 AM", startTs, endTs, "2026-01-01", title, "test summary", "Work"])
      return db.lastInsertedRowID
    }
  }

  // MARK: - Activity reads (injected storage)

  func testActivitiesReturnsOnlyCardsFromInjectedStorage() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)

    let base = 1_700_000_000
    try insertTimelineCard(in: storage, title: "Injected One", startTs: base, endTs: base + 300)
    try insertTimelineCard(in: storage, title: "Injected Two", startTs: base + 600, endTs: base + 900)

    // Narrow range overlapping only the second card: overlap semantics are
    // storage's, so this pins the same (start_ts < to AND end_ts > from) OR
    // (start within range) behavior the production query uses.
    let narrow = engine.activities(
      from: Date(timeIntervalSince1970: TimeInterval(base + 650)),
      to: Date(timeIntervalSince1970: TimeInterval(base + 1_000)))
    XCTAssertEqual(narrow.map(\.title), ["Injected Two"])

    // Wide range returns both, oldest first (start_ts ASC ordering).
    let wide = engine.activities(
      from: Date(timeIntervalSince1970: TimeInterval(base - 60)),
      to: Date(timeIntervalSince1970: TimeInterval(base + 1_000)))
    XCTAssertEqual(wide.map(\.title), ["Injected One", "Injected Two"])
    XCTAssertEqual(wide.compactMap(\.recordId).count, 2)
  }

  func testActivitiesReturnsNoCardsForAFutureRange() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)
    let now = Int(Date().timeIntervalSince1970)
    try insertTimelineCard(in: storage, title: "Current", startTs: now - 60, endTs: now)

    let future = Date().addingTimeInterval(24 * 60 * 60)

    let cards = engine.activities(from: future, to: future.addingTimeInterval(60))

    XCTAssertTrue(cards.isEmpty)
  }

  func testActivitiesDoesNotRequireEngineLifecycle() throws {
    // The read path must work on a freshly constructed engine (headless use:
    // no start(), no recorder, no analysis job) against injected storage.
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)
    try insertTimelineCard(
      in: storage, title: "Headless", startTs: 1_700_000_000, endTs: 1_700_000_300)

    let cards = engine.activities(from: .distantPast, to: .distantFuture)

    XCTAssertEqual(cards.map(\.title), ["Headless"])
  }

  func testActivitiesDoesNotSeeDataInAnotherIsolatedStore() throws {
    let storageA = makeIsolatedStorage()
    let engineA = MacActivityEngine(storage: storageA)
    let storageB = makeIsolatedStorage()
    let engineB = MacActivityEngine(storage: storageB)

    try insertTimelineCard(
      in: storageA, title: "Only In A", startTs: 1_700_000_000, endTs: 1_700_000_300)

    XCTAssertEqual(engineA.activities(from: .distantPast, to: .distantFuture).map(\.title), ["Only In A"])
    XCTAssertTrue(engineB.activities(from: .distantPast, to: .distantFuture).isEmpty)
  }

  // MARK: - Reprocessing (delegation only — NOT storage-injected)

  /// Exercises the reprocessDay delegation end to end against a day that
  /// cannot have any recorded data (long before Dayflow existed): no real
  /// cards are deleted, no batches are reset, and no LLM work is queued —
  /// the machinery takes its empty-day early exit.
  ///
  /// Destructive real-day reprocessing is intentionally NOT tested here.
  ///
  /// Note: reprocessDay still delegates to `AnalysisManager.shared`, whose
  /// storage remains global; an engine constructed with isolated storage
  /// does NOT reprocess through that injected store.
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

  // MARK: - Processing status (persisted counts from injected storage)

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

  func testProcessingStatusMatchesPersistedBatchStatuses() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)

    // Persisted batch rows with known statuses, arranged directly in the
    // isolated database (both terminal-success spellings included).
    try storage.db.write { db in
      for status in ["analyzed", "completed", "pending", "pending", "failed"] {
        try db.execute(
          sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, ?)",
          arguments: [status])
      }
    }

    let status = engine.processingStatus()
    let batches = storage.allBatches()

    XCTAssertEqual(
      status.analyzedBatchCount,
      batches.filter { ActivityProcessingStatus.isSuccessStatus($0.status) }.count)
    XCTAssertEqual(
      status.pendingBatchCount,
      batches.filter { $0.status == "pending" }.count)
    XCTAssertEqual(
      status.failedBatchCount,
      batches.filter { $0.status == "failed" }.count)
    XCTAssertEqual(status.analyzedBatchCount, 2)
    XCTAssertEqual(status.pendingBatchCount, 2)
    XCTAssertEqual(status.failedBatchCount, 1)
  }

  /// The in-flight count still comes from the shared AnalysisManager's
  /// in-memory tracker (not storage-injected yet): a snapshot can combine
  /// injected-storage batch counts with production/global in-flight state.
  /// It is normally 0 unless the hosted app is running analysis work.
  func testProcessingStatusInFlightCountComesFromSharedAnalysisManager() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)

    try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, 'pending')"
      )
    }

    let status = engine.processingStatus()

    XCTAssertEqual(status.inFlightBatchCount, AnalysisManager.shared.inFlightBatchCount)
    XCTAssertEqual(status.pendingBatchCount, 1)
    XCTAssertEqual(status.isAnalyzing, status.inFlightBatchCount > 0)
  }

  func testProcessingStatusOfFreshIsolatedStorageIsZeroed() {
    let engine = MacActivityEngine(storage: makeIsolatedStorage())

    let status = engine.processingStatus()

    XCTAssertEqual(status.analyzedBatchCount, 0)
    XCTAssertEqual(status.pendingBatchCount, 0)
    XCTAssertEqual(status.inFlightBatchCount, 0)
    XCTAssertEqual(status.failedBatchCount, 0)
    XCTAssertFalse(status.isAnalyzing)
  }

  func testProcessingStatusSnapshotIsSane() throws {
    let storage = makeIsolatedStorage()
    let engine = MacActivityEngine(storage: storage)
    try storage.db.write { db in
      for status in ["analyzed", "failed_empty", "skipped_short"] {
        try db.execute(
          sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (100, 200, ?)",
          arguments: [status])
      }
    }

    let status = engine.processingStatus()

    XCTAssertGreaterThanOrEqual(status.analyzedBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.pendingBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.inFlightBatchCount, 0)
    XCTAssertGreaterThanOrEqual(status.failedBatchCount, 0)
    XCTAssertEqual(status.isAnalyzing, status.inFlightBatchCount > 0)
    // Terminal no-output outcomes count as neither success nor failure.
    XCTAssertEqual(status.analyzedBatchCount, 1)
    XCTAssertEqual(status.pendingBatchCount, 0)
    XCTAssertEqual(status.failedBatchCount, 0)
    // In-flight batches are executing now, so they cannot be idle-negative;
    // the tracker is the authoritative "now" signal.
    let batches = storage.allBatches()
    XCTAssertLessThanOrEqual(
      status.pendingBatchCount + status.failedBatchCount + status.analyzedBatchCount,
      batches.count)
  }

  // MARK: - Activity change signal

  /// The façade's observer must receive the engine-owned signal (pins the
  /// wiring: engine surface and storage emission share one notification).
  func testObserveActivityChangesExposesEngineSignal() {
    let signalReceived = expectation(description: "activity change signal")
    let token = MacActivityEngineSignals.observeActivityChanges { _ in
      signalReceived.fulfill()
    }
    addTeardownBlock { NotificationCenter.default.removeObserver(token) }

    NotificationCenter.default.post(name: .timelineActivitiesChanged, object: nil)

    wait(for: [signalReceived], timeout: 1.0)
  }

  /// A real storage timeline-card mutation path (title update) commits a
  /// transaction and emits the signal. Uses an isolated storage instance —
  /// the signal is storage-instance-agnostic (engine-owned, global name) —
  /// and probes with a card ID that cannot exist, so no timeline data is
  /// modified anywhere.
  func testTimelineCardUpdateEmitsActivityChangeSignal() {
    let storage = makeIsolatedStorage()
    let signalReceived = expectation(description: "activity change signal")
    let token = MacActivityEngineSignals.observeActivityChanges { _ in
      signalReceived.fulfill()
    }
    addTeardownBlock { NotificationCenter.default.removeObserver(token) }

    storage.updateTimelineCardTitle(cardId: -1, title: "signal probe")

    wait(for: [signalReceived], timeout: 5.0)
  }

  /// The empty-batch-ID guard returns before any write transaction, so a
  /// true no-op must not emit. (Committed transactions may still emit even
  /// when they match zero rows — that coarse case is documented on the
  /// signal.) Uses an isolated storage instance.
  func testGuardedNoOpDeletionDoesNotEmitSignal() {
    let storage = makeIsolatedStorage()
    let unexpectedSignal = expectation(description: "no signal expected")
    unexpectedSignal.isInverted = true
    let token = MacActivityEngineSignals.observeActivityChanges { _ in
      unexpectedSignal.fulfill()
    }
    addTeardownBlock { NotificationCenter.default.removeObserver(token) }

    storage.deleteTimelineCards(forBatchIds: [])

    wait(for: [unexpectedSignal], timeout: 0.3)
  }

  // MARK: - Capture control

  /// Read-only mirror only: exercising startCapture/stopCapture in tests
  /// would start/stop real screen capture (the hosted app's recorder is
  /// subscribed to the recording state) and persist real recording
  /// preferences, so the mutation path is verified by static delegation
  /// (each façade method is a single call to the canonical
  /// RecordingState.setRecording mutation) rather than executed here.
  func testIsCaptureEnabledMirrorsRecordingControlState() {
    let engine = MacActivityEngine()

    XCTAssertEqual(engine.isCaptureEnabled, RecordingState.shared.isRecording)
  }
}
