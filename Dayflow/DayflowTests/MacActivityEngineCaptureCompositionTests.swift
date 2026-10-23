import XCTest

@testable import Dayflow

/// Minimal analysis fake for capture-composition tests: the engine's
/// analysis-facing surface is never exercised here (no `startAnalysisJob()`,
/// so no recurring timer), but `processingStatus()` reads its in-flight
/// count and the engine must be constructed with a full dependency set.
private final class CaptureCompositionFakeAnalysis: AnalysisManaging,
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

/// First proof of the capture stack composed through the `MacActivityEngine`
/// façade:
///
/// ```text
/// isolated engine
///   → engine.start() (injected recorder factory)
///   → engine.startCapture() (injected RecordingState)
///   → REAL ScreenRecorder
///   → FAKE capture source (shared fake from the recorder seam tests)
///   → synthetic frame → isolated FrameStore / SQLite / recordings root
///   → engine.stopCapture() → segment finalized
/// ```
///
/// No real ScreenCaptureKit, no TCC screen-recording permission, no
/// production database/files, no production RecordingState, no actual desktop
/// screenshot, and no recurring analysis scheduling. Test methods are `async`
/// so the capture path's `MainActor` hops can proceed while the test polls.
@MainActor
final class MacActivityEngineCaptureCompositionTests: XCTestCase {
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
        "dayflow-engine-capture-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeIsolatedState() -> RecordingState {
    let name = "engine-capture-state-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.append((defaults, name))
    return RecordingState(defaults: defaults)
  }

  /// Machine-independent host defaults for the capture path, restored
  /// afterwards: an empty privacy blocklist (frontmost-app placeholder branch
  /// can't trigger) and a 60 s capture interval (only the immediate first
  /// tick can run during the test).
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

  // MARK: - Tests

  func testEngineFaçadeDrivesIsolatedCaptureStackEndToEnd() async throws {
    isolateHostCaptureDefaults()
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()
    let fake = FakeCaptureSource()
    var factoryCalls = 0

    let engine = MacActivityEngine(
      storage: storage,
      analysis: CaptureCompositionFakeAnalysis(),
      recordingState: state,
      makeRecorder: { state in
        factoryCalls += 1
        return ScreenRecorder(
          autoStart: true, frameStore: frames, recordingState: state, captureSource: fake)
      }
    )

    // Construction alone builds nothing: the recorder factory is not invoked
    // until start(), preserving the engine's lifecycle point.
    XCTAssertEqual(factoryCalls, 0)
    XCTAssertFalse(engine.isCaptureEnabled, "isolated state starts false")
    XCTAssertEqual(fake.captureImageCalls, 0)
    XCTAssertNil(frames.activeSegmentPath)

    // start(): seeds the isolated state low, then constructs the recorder
    // through the injected factory — once, exactly as before.
    engine.start()
    XCTAssertEqual(factoryCalls, 1)
    XCTAssertFalse(engine.isCaptureEnabled)
    // autoStart saw a false state at construction: no capture began.
    XCTAssertEqual(fake.permissionChecks, 0)
    XCTAssertEqual(fake.captureImageCalls, 0)
    XCTAssertNil(frames.activeSegmentPath)

    // startCapture(): the façade turns on the injected RecordingState, which
    // the constructed recorder observes — fake capture, real append path.
    engine.startCapture()
    XCTAssertTrue(engine.isCaptureEnabled)

    let captureDeadline = Date().addingTimeInterval(10)
    var rows: [Screenshot] = []
    while Date() < captureDeadline {
      rows = storage.fetchUnprocessedScreenshots(since: 0)
      if !rows.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertFalse(rows.isEmpty, "engine-driven fake capture should append a row")
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(fake.captureImageCalls, 1)

    let row = try XCTUnwrap(rows.first)
    let openPath = try XCTUnwrap(frames.activeSegmentPath)
    XCTAssertTrue(openPath.hasPrefix(root.path), "segment must live under the isolated root")
    XCTAssertEqual(row.filePath, openPath)
    XCTAssertNotNil(row.frameIndex)
    XCTAssertGreaterThan(row.capturedAt, 0)
    XCTAssertFalse(row.isDeleted)

    // stopCapture(): the façade turns the same injected state off; the
    // recorder's stop branch finalizes the isolated frame store's segment.
    engine.stopCapture()
    XCTAssertFalse(engine.isCaptureEnabled)

    let finalizeDeadline = Date().addingTimeInterval(10)
    while frames.activeSegmentPath != nil && Date() < finalizeDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPath))
    let finalRows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(finalRows.count, 1)
    XCTAssertEqual(finalRows.first?.filePath, openPath)
    XCTAssertNotNil(finalRows.first?.fileSize, "finalized segment should report its size")

    // Engine read/status APIs keep using their injected dependencies: an
    // empty isolated storage and the injected analysis fake, not production
    // singletons.
    let status = engine.processingStatus()
    XCTAssertEqual(
      status,
      ActivityProcessingStatus(
        analyzedBatchCount: 0, pendingBatchCount: 0, inFlightBatchCount: 0,
        failedBatchCount: 0))
    XCTAssertTrue(
      engine.activities(from: Date().addingTimeInterval(-60), to: Date()).isEmpty,
      "timeline reads must come from the isolated storage")
  }

  func testRepeatedStartReplacesRecorderPerExistingLifecycleSemantics() async throws {
    isolateHostCaptureDefaults()
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()
    let fake = FakeCaptureSource()
    var factoryCalls = 0

    let engine = MacActivityEngine(
      storage: storage,
      analysis: CaptureCompositionFakeAnalysis(),
      recordingState: state,
      makeRecorder: { state in
        factoryCalls += 1
        return ScreenRecorder(
          autoStart: true, frameStore: frames, recordingState: state, captureSource: fake)
      }
    )

    // start() has no guard today: a second call re-seeds the state and
    // constructs a replacement recorder. Preserved exactly — documented here
    // so a future "fix" can't slip in silently.
    engine.start()
    engine.start()
    XCTAssertEqual(factoryCalls, 2)
    XCTAssertFalse(engine.isCaptureEnabled)

    // The engine still holds exactly one live recorder: capture through the
    // façade lands one frame, not two.
    engine.startCapture()
    let captureDeadline = Date().addingTimeInterval(10)
    var rows: [Screenshot] = []
    while Date() < captureDeadline {
      rows = storage.fetchUnprocessedScreenshots(since: 0)
      if !rows.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(fake.captureImageCalls, 1)

    engine.stopCapture()
    let finalizeDeadline = Date().addingTimeInterval(10)
    while frames.activeSegmentPath != nil && Date() < finalizeDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertEqual(storage.fetchUnprocessedScreenshots(since: 0).count, 1)
  }
}
