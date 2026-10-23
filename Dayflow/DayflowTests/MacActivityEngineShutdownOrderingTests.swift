import XCTest

@testable import Dayflow

/// Minimal analysis fake for the shutdown-ordering test: `shutdown()` never
/// exercises analysis, but the engine must be constructed with a full
/// dependency set and `processingStatus()` reads the in-flight count.
private final class ShutdownOrderingFakeAnalysis: AnalysisManaging,
  @unchecked Sendable
{
  let inFlightBatchCount = 0

  func startAnalysisJob() { fatalError("unexpected call") }
  func stopAnalysisJob() { fatalError("unexpected call") }
  func triggerAnalysisNow() { fatalError("unexpected call") }
  func reprocessDay(
    _ day: String,
    progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    fatalError("unexpected call")
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

/// Termination-ordering proof for `MacActivityEngine.shutdown()`:
///
/// ```text
/// engine.start() → engine.startCapture() (fake source, isolated stack)
///   → real captured screenshot row (segment still OPEN, no file size yet)
///   → engine.shutdown()            ← NO engine.stopCapture() first
///   → shutdown() RETURNS synchronously
/// ```
///
/// Everything asserted below is checked IMMEDIATELY after `shutdown()`
/// returns — no polling for finalization. That is the point: the recorder's
/// final segment finalization and its metadata/file-size database writes must
/// have completed BEFORE the storage truncate checkpoint ran, and both must
/// be observable the instant shutdown returns.
///
/// The happens-before oracle (no storage spy needed): the row's `file_size`
/// is NULL while the segment is open and is only written by
/// `FrameStore.finishWriterLocked()` inside the recorder's synchronous stop;
/// the WAL is only zero-length if `checkpointTruncate()` ran LAST. Asserting
/// both — `fileSize != nil` AND WAL == 0 — after return proves the final
/// FrameStore write happened-before the truncate checkpoint. If the
/// checkpoint had run first, the final write would have re-grown the WAL
/// after the truncate.
@MainActor
final class MacActivityEngineShutdownOrderingTests: XCTestCase {
  private var tempRoots: [URL] = []
  private var suites: [(defaults: UserDefaults, name: String)] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    for (defaults, name) in suites {
      defaults.removePersistentDomain(forName: name)
    }
    suites.removeAll()
    super.tearDown()
  }

  // MARK: - Fixtures

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "dayflow-engine-shutdown-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeIsolatedState() -> RecordingState {
    let name = "engine-shutdown-state-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.append((defaults, name))
    return RecordingState(defaults: defaults)
  }

  /// Machine-independent host capture defaults, restored afterwards: an empty
  /// privacy blocklist (frontmost-app placeholder branch can't trigger) and a
  /// 60 s capture interval (only the immediate first tick can run).
  private func isolateHostCaptureDefaults() {
    let defaults = UserDefaults.standard
    let originalBlocked = RecordingPrivacyPreferences.blockedApplicationsText(defaults: defaults)
    let originalInterval = defaults.object(forKey: ScreenshotConfig.intervalKey)
    RecordingPrivacyPreferences.saveBlockedApplicationsText("", defaults: defaults)
    defaults.set(60, forKey: ScreenshotConfig.intervalKey)
    addTeardownBlock {
      RecordingPrivacyPreferences.saveBlockedApplicationsText(originalBlocked, defaults: defaults)
      if let interval = originalInterval {
        defaults.set(interval, forKey: ScreenshotConfig.intervalKey)
      } else {
        defaults.removeObject(forKey: ScreenshotConfig.intervalKey)
      }
    }
  }

  /// Polls `condition` on a short interval until it holds or the deadline
  /// passes; returns the final evaluation. (Used only BEFORE shutdown, to
  /// wait for capture — never to wait for shutdown's effects.)
  @discardableResult
  private func waitUntil(
    timeout: TimeInterval, _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
  }

  // MARK: - Test

  func testShutdownFinishesRecorderWorkBeforeTruncateCheckpointWithoutStopCapture() async throws {
    isolateHostCaptureDefaults()
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()
    let fake = FakeCaptureSource()
    let walPath = storage.dbURL.path + "-wal"

    let engine = MacActivityEngine(
      storage: storage,
      analysis: ShutdownOrderingFakeAnalysis(),
      recordingState: state,
      makeRecorder: { state in
        ScreenRecorder(
          autoStart: true, frameStore: frames, recordingState: state, captureSource: fake)
      })

    engine.start()
    engine.startCapture()

    // Wait (before shutdown) until the real capture path appended its row.
    let captured = await waitUntil(timeout: 10) {
      !storage.fetchUnprocessedScreenshots(since: 0).isEmpty
    }
    XCTAssertTrue(captured, "engine-driven fake capture should append a row")

    // Pre-shutdown state: one row, its segment still OPEN — no file size yet.
    // This is what makes the post-shutdown `fileSize != nil` a meaningful
    // ordering artifact: the size write can only come from the synchronous
    // finalization performed inside shutdown.
    let openRows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(openRows.count, 1)
    let openRow = try XCTUnwrap(openRows.first)
    XCTAssertNil(openRow.fileSize, "open segment has no file size yet")
    let segmentPath = try XCTUnwrap(frames.activeSegmentPath)
    XCTAssertEqual(openRow.filePath, segmentPath)
    XCTAssertTrue(segmentPath.hasPrefix(root.path))
    XCTAssertEqual(fake.captureImageCalls, 1)

    // SHUTDOWN — deliberately WITHOUT engine.stopCapture() first, exactly
    // like termination while actively recording. Synchronous: no polling for
    // finalization is performed afterwards.
    engine.shutdown()

    // Immediately after shutdown() returns:

    // 1. The owned recorder's frame store has no open segment.
    XCTAssertNil(frames.activeSegmentPath, "segment must be finalized when shutdown returns")

    // 2. The finalized segment file exists under the isolated root.
    XCTAssertTrue(FileManager.default.fileExists(atPath: segmentPath))

    // 3. The captured row remains persisted — and 4. its file size was
    // populated by the synchronous finalization (the happens-before artifact:
    // this write happened inside shutdown, before the checkpoint).
    let finalRows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(finalRows.count, 1, "no additional capture rows after shutdown")
    let finalRow = try XCTUnwrap(finalRows.first)
    XCTAssertEqual(finalRow.filePath, segmentPath)
    XCTAssertNotNil(finalRow.fileSize, "final segment size must be written before shutdown returns")
    XCTAssertFalse(finalRow.isDeleted)

    // 5. No further capture work can run: acquisition stopped at one call,
    // and the row count is stable (a brief negative sanity check — NOT a
    // wait for finalization, which is already complete above).
    XCTAssertEqual(fake.captureImageCalls, 1)
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(storage.fetchUnprocessedScreenshots(since: 0).count, 1)
    XCTAssertEqual(fake.captureImageCalls, 1)
    XCTAssertNil(frames.activeSegmentPath)

    // The user's recording preference is untouched by termination: the engine
    // stopped the RECORDER directly, without driving RecordingState. The
    // flag (and the persisted preference, once the host enables persistence)
    // still says "recording on" for the next launch.
    XCTAssertTrue(engine.isCaptureEnabled)

    // 6/7. Checkpoint ordering proof + storage remains usable. The WAL is
    // zero-length, i.e. the truncate checkpoint ran LAST — after the final
    // segment size write (which would otherwise have re-grown the WAL).
    // Read with the raw `stat` syscall because URL resource values cache.
    func walSize() -> Int {
      var s = stat()
      return stat(walPath, &s) == 0 ? Int(s.st_size) : -1
    }
    XCTAssertEqual(walSize(), 0, "truncate checkpoint must run after the final recorder writes")

    // The isolated database is still fully usable after the checkpoint:
    // a write commits and reads back.
    try await storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (1, 2, 'pending')"
      )
    }
    XCTAssertEqual(storage.allBatches().count, 1)

    // Repeated shutdown stays harmless (idempotent finalization + repeatable
    // checkpoint) — same effective behavior as before this ordering fix.
    engine.shutdown()
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertEqual(storage.fetchUnprocessedScreenshots(since: 0).count, 1)
    XCTAssertEqual(fake.captureImageCalls, 1)
    XCTAssertEqual(walSize(), 0)
  }
}
