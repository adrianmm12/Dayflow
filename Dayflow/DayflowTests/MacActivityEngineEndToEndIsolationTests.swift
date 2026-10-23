import XCTest

@testable import Dayflow

/// Fake provider EXECUTION for the end-to-end isolation pipeline: the
/// `LLMServiceProviderInjectionTests` fake, extended with the behavioral
/// isolation proof — every screenshot the REAL `LLMService` hands it is
/// decoded through the SAME isolated `FrameStore` that captured it
/// (`Screenshot.loadCGImage(from:)`, never the `.shared` convenience).
///
/// Routing still runs through the real `LLMProviderRoutingStore`; only the
/// transcription / card-generation closures are fake. No network, CLI,
/// keychain, or `LLMLogger` is reachable. This fake deliberately does not
/// persist `llm_calls` rows — matching the existing fake-provider route,
/// where the service does not persist provider logs per batch.
private final class EndToEndFakeProviderFactory {
  private let lock = NSLock()
  private var _requestedProviderIDs: [LLMProviderID] = []
  private var _transcriptionCallCount = 0
  private var _cardGenerationCallCount = 0
  private var _decodedScreenshotCount = 0
  private var _decodeFailureCount = 0
  private var _wrongSizedDecodeCount = 0

  /// The isolated capture store: the same instance that appended the frames.
  private let frameStore: FrameStore

  init(frameStore: FrameStore) {
    self.frameStore = frameStore
  }

  var requestedProviderIDs: [LLMProviderID] { lock.withLock { _requestedProviderIDs } }
  var transcriptionCallCount: Int { lock.withLock { _transcriptionCallCount } }
  var cardGenerationCallCount: Int { lock.withLock { _cardGenerationCallCount } }
  var decodedScreenshotCount: Int { lock.withLock { _decodedScreenshotCount } }
  var decodeFailureCount: Int { lock.withLock { _decodeFailureCount } }
  var wrongSizedDecodeCount: Int { lock.withLock { _wrongSizedDecodeCount } }

  static let fakeObservationText = "fake transcript entry"
  static let fakeCardTitle = "Fake Activity"
  static let fakeModel = "fake-model"

  func providerContext(for providerID: LLMProviderID) throws
    -> LLMService.TimelineProviderContext
  {
    lock.withLock { _requestedProviderIDs.append(providerID) }

    let clock = DateFormatter()
    clock.dateFormat = "h:mm a"
    clock.locale = Locale(identifier: "en_US_POSIX")
    clock.timeZone = TimeZone.current

    let actions = LLMService.BatchProviderActions(
      transcribeScreenshots: { [weak self] screenshots, batchStartTime, batchId in
        guard let self else {
          throw NSError(
            domain: "EndToEndFakeProvider", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "factory deallocated"])
        }
        self.lock.withLock { self._transcriptionCallCount += 1 }

        // BEHAVIORAL ISOLATION PROOF: decode every screenshot through the same
        // isolated FrameStore that captured it. The synthetic frames are
        // 320×240; a decode failure here would mean the semantic path jumped
        // to a store that never owned this segment.
        for screenshot in screenshots {
          if let image = screenshot.loadCGImage(from: self.frameStore) {
            self.lock.withLock {
              self._decodedScreenshotCount += 1
              if image.width != 320 || image.height != 240 {
                self._wrongSizedDecodeCount += 1
              }
            }
          } else {
            self.lock.withLock { self._decodeFailureCount += 1 }
          }
        }

        let startTs = Int(batchStartTime.timeIntervalSince1970)
        let observations = [
          Observation(
            id: nil, batchId: batchId ?? 0, startTs: startTs, endTs: startTs + 300,
            observation: Self.fakeObservationText, metadata: nil, llmModel: Self.fakeModel,
            createdAt: nil),
          Observation(
            id: nil, batchId: batchId ?? 0, startTs: startTs + 300, endTs: startTs + 600,
            observation: Self.fakeObservationText, metadata: nil, llmModel: Self.fakeModel,
            createdAt: nil),
        ]
        return (
          observations: observations,
          log: LLMCall(timestamp: Date(), latency: 0.01, input: "fake-in", output: "fake-out")
        )
      },
      generateActivityCards: { [weak self] observations, context, _ in
        guard let self else {
          throw NSError(
            domain: "EndToEndFakeProvider", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "factory deallocated"])
        }
        self.lock.withLock { self._cardGenerationCallCount += 1 }
        // One card inside the batch window, derived from the window's current
        // time so the service's clock-string parsing lands it in the
        // replacement range.
        let card = ActivityCardData(
          startTime: clock.string(from: context.currentTime.addingTimeInterval(-11 * 60)),
          endTime: clock.string(from: context.currentTime.addingTimeInterval(-2 * 60)),
          category: "Work",
          subcategory: "Testing",
          title: Self.fakeCardTitle,
          summary: "fake summary",
          detailedSummary: "fake detailed summary",
          distractions: nil,
          appSites: nil)
        return (
          cards: [card], rewriteSpan: nil,
          log: LLMCall(timestamp: Date(), latency: 0.01, input: "fake-in", output: "fake-out")
        )
      }
    )
    return LLMService.TimelineProviderContext(
      id: providerID,
      providerLabel: "fake-\(providerID.rawValue)",
      actions: actions,
      fallbackState: nil
    )
  }
}

/// The FIRST complete deterministic engine pipeline:
///
/// ```text
/// fake screen (FakeCaptureSource)
///     ↓
/// REAL MacActivityEngine façade (start/startCapture/stopCapture)
///     ↓
/// REAL ScreenRecorder
///     ↓
/// REAL FrameStore (isolated)
///     ↓
/// isolated HEVC segment + screenshot rows
///     ↓
/// REAL AnalysisManager (triggerAnalysisNow)
///     ↓
/// REAL LLMService (isolated storage + SAME isolated FrameStore)
///     ↓
/// fake provider execution
///     ↓
/// REAL observations + timeline cards in the isolated store
/// ```
///
/// No real desktop capture (the fake source supplies synthetic 320×240
/// frames), no real model, no production DB/files, no production FrameStore,
/// no cloud/network inference. The screenshot rows originate from the real
/// engine → recorder → FrameStore capture path — never inserted by hand.
///
/// Batching eligibility (inspected, not weakened): the real service's
/// `batchingConfig` is `.standard` (15-minute target duration, 2-minute max
/// gap), and `AnalysisManager.createScreenshotBatches` DROPS the most-recent
/// batch when its span is under 900 s — so a just-captured cluster of frames
/// can never be batched as captured. After the real capture phase, this test
/// applies the sanctioned minimal fixture adjustment (existing raw-SQL
/// mechanism, `storage.db.write`): the ISOLATED rows' `captured_at` values
/// are spread 100 s apart anchored 900 s in the past (span exactly 900 s, one
/// bucket, kept batch), and `idle_seconds_at_capture` is normalized to 0.
/// The idle normalization keeps the deterministic non-idle LLM path: host HID
/// idle is machine state, and a host idle ≥ 60 s at every tick would make the
/// real `IdleBatchClassifier` legitimately short-circuit to an idle card.
/// Production scheduling, batching, and idle rules are untouched.
@MainActor
final class MacActivityEngineEndToEndIsolationTests: XCTestCase {
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
        "dayflow-engine-e2e-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeIsolatedState() -> RecordingState {
    let name = "engine-e2e-state-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.append((defaults, name))
    return RecordingState(defaults: defaults)
  }

  /// Machine-independent host defaults for the whole pipeline, restored
  /// afterwards:
  /// - an empty privacy blocklist (frontmost-app placeholder branch can't
  ///   trigger, whatever app is frontmost on this machine);
  /// - a 1 s capture interval so the real recorder can capture the required
  ///   frame count in seconds (first tick is immediate, then one per second);
  /// - persistent timelapses OFF so the post-batch timelapse hook stays a
  ///   deterministic no-op regardless of this machine's settings.
  private func isolateHostDefaults() {
    let defaults = UserDefaults.standard
    let originalBlocked = RecordingPrivacyPreferences.blockedApplicationsText(defaults: defaults)
    let originalInterval = defaults.object(forKey: ScreenshotConfig.intervalKey)
    let originalTimelapses = defaults.object(forKey: TimelapsePreferences.saveAllTimelapsesToDiskKey)
    RecordingPrivacyPreferences.saveBlockedApplicationsText("", defaults: defaults)
    defaults.set(1, forKey: ScreenshotConfig.intervalKey)
    defaults.set(false, forKey: TimelapsePreferences.saveAllTimelapsesToDiskKey)
    addTeardownBlock {
      RecordingPrivacyPreferences.saveBlockedApplicationsText(originalBlocked, defaults: defaults)
      if let interval = originalInterval {
        defaults.set(interval, forKey: ScreenshotConfig.intervalKey)
      } else {
        defaults.removeObject(forKey: ScreenshotConfig.intervalKey)
      }
      if let timelapses = originalTimelapses {
        defaults.set(timelapses, forKey: TimelapsePreferences.saveAllTimelapsesToDiskKey)
      } else {
        defaults.removeObject(forKey: TimelapsePreferences.saveAllTimelapsesToDiskKey)
      }
    }
  }

  /// Polls `condition` on a short interval until it holds or the deadline
  /// passes; returns the final evaluation.
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

  func testFullPipelineFromFakeScreenThroughEngineToTimelineCards() async throws {
    isolateHostDefaults()

    // ONE coherent object graph: a single isolated StorageManager + FrameStore
    // pair flows through capture AND semantic decoding; the same FrameStore
    // instance is the capture writer (recorder) and the screenshot decoder
    // (provider), and is passed EXPLICITLY into LLMService — no `.shared`
    // silent fallback anywhere in this composition.
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()
    let fakeSource = FakeCaptureSource()
    let fakeProvider = EndToEndFakeProviderFactory(frameStore: frames)
    let llmService = LLMService(
      storage: storage,
      frameStore: frames,
      providerContextFor: fakeProvider.providerContext(for:))
    let analysisManager = AnalysisManager(storage: storage, llmService: llmService)

    var factoryCalls = 0
    let engine = MacActivityEngine(
      storage: storage,
      analysis: analysisManager,
      recordingState: state,
      makeRecorder: { state in
        factoryCalls += 1
        return ScreenRecorder(
          autoStart: true, frameStore: frames, recordingState: state, captureSource: fakeSource)
      })

    // MARK: Capture phase — driven through the ENGINE façade only.

    engine.start()
    XCTAssertEqual(factoryCalls, 1)
    XCTAssertFalse(engine.isCaptureEnabled)

    engine.startCapture()
    XCTAssertTrue(engine.isCaptureEnabled)

    // The real batching window needs a 900 s span; 10 frames at 100 s
    // spacing is the smallest clean geometry. Capture a few more than
    // needed — the tail rows are deterministically dropped by the real
    // "incomplete last batch" rule (they form a sub-900 s tail bucket).
    let targetFrameCount = 10
    let capturedEnough = await waitUntil(timeout: 30) {
      storage.fetchUnprocessedScreenshots(since: 0).count >= targetFrameCount
    }
    XCTAssertTrue(
      capturedEnough,
      "engine-driven fake capture should append at least \(targetFrameCount) rows")

    engine.stopCapture()
    XCTAssertFalse(engine.isCaptureEnabled)
    let finalized = await waitUntil(timeout: 10) { frames.activeSegmentPath == nil }
    XCTAssertTrue(finalized, "stopCapture should finalize the segment")

    // Capture assertions BEFORE semantic processing: the rows exist in the
    // isolated DB, the recording file lives under the isolated root, the
    // segment finalized with sizes, and acquisition went through the fake
    // source only — production ScreenCaptureKit was never used.
    let capturedRows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertGreaterThanOrEqual(capturedRows.count, targetFrameCount)
    XCTAssertGreaterThanOrEqual(fakeSource.captureImageCalls, targetFrameCount)

    let segmentPath = try XCTUnwrap(capturedRows.first?.filePath)
    XCTAssertTrue(segmentPath.hasPrefix(root.path), "segment must live under the isolated root")
    XCTAssertTrue(FileManager.default.fileExists(atPath: segmentPath))
    for row in capturedRows {
      XCTAssertEqual(row.filePath, segmentPath, "one segment holds every captured frame")
      XCTAssertNotNil(row.frameIndex)
      XCTAssertNotNil(row.fileSize, "finalized segment should report its size")
      XCTAssertFalse(row.isDeleted)
    }

    // MARK: Fixture adjustment (sanctioned, documented above): spread the
    // REAL captured rows across the batchable window and pin idle to 0.

    let orderedRows = capturedRows.sorted { $0.id < $1.id }
    let referenceTs = Int(Date().timeIntervalSince1970) - 900
    try await storage.db.write { db in
      for (index, row) in orderedRows.enumerated() {
        try db.execute(
          sql: "UPDATE screenshots SET captured_at = ?, idle_seconds_at_capture = 0 WHERE id = ?",
          arguments: [referenceTs + index * 100, row.id])
      }
    }

    // MARK: Analysis phase — REAL AnalysisManager, one-shot trigger (no
    // recurring timer: triggerAnalysisNow, never startAnalysisJob).

    analysisManager.triggerAnalysisNow()

    let analysisCompleted = await waitUntil(timeout: 30) {
      let batches = storage.allBatches()
      guard batches.count == 1, batches.first?.3 == "completed" else { return false }
      return !storage.fetchTimelineCardsByTimeRange(
        from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(60)
      ).isEmpty
    }
    XCTAssertTrue(
      analysisCompleted,
      "the real analysis pipeline should reach its successful terminal state")

    let batches = storage.allBatches()
    XCTAssertEqual(batches.count, 1, "exactly one kept batch (the 900 s span)")
    let batchID = try XCTUnwrap(batches.first?.0)
    XCTAssertEqual(batches.first?.3, "completed", "terminal batch status")
    XCTAssertEqual(analysisManager.inFlightBatchCount, 0)
    XCTAssertTrue(analysisManager.isBatchInFlight(batchID) == false)

    // The batch joined exactly the 10 window screenshots (the tail rows were
    // dropped by the real incomplete-last-batch rule).
    let batchRows = storage.screenshotsForBatch(batchID)
    XCTAssertEqual(batchRows.count, targetFrameCount)

    // MARK: Semantic layer — persisted through the REAL service path.

    // Provider execution: the real service asked the injected factory for the
    // routing-chosen provider's context and ran both inference stages
    // through the fake — nothing contacted a real provider.
    XCTAssertFalse(fakeProvider.requestedProviderIDs.isEmpty)
    XCTAssertEqual(fakeProvider.transcriptionCallCount, 1)
    XCTAssertEqual(fakeProvider.cardGenerationCallCount, 1)

    // BEHAVIORAL PROOF of the coherent FrameStore: the provider decoded every
    // batched screenshot through the SAME isolated store that captured it —
    // the captured HEVC frames came back as the synthetic 320×240 pixels the
    // fake screen supplied. `FrameStore.shared` never owned this segment.
    XCTAssertEqual(fakeProvider.decodedScreenshotCount, targetFrameCount)
    XCTAssertEqual(fakeProvider.decodeFailureCount, 0)
    XCTAssertEqual(fakeProvider.wrongSizedDecodeCount, 0)

    // Same proof from the test side: the frame is readable through the one
    // isolated FrameStore instance.
    let decodedRow = try XCTUnwrap(batchRows.first)
    let decoded = try XCTUnwrap(frames.image(for: decodedRow))
    XCTAssertEqual(decoded.width, 320)
    XCTAssertEqual(decoded.height, 240)

    // Observations persisted by the real service into the isolated store.
    let observations = storage.fetchObservations(batchId: batchID)
    XCTAssertEqual(observations.count, 2)
    XCTAssertTrue(
      observations.allSatisfy {
        $0.observation == EndToEndFakeProviderFactory.fakeObservationText
      })
    XCTAssertTrue(observations.allSatisfy { $0.llmModel == EndToEndFakeProviderFactory.fakeModel })
    XCTAssertTrue(observations.allSatisfy { $0.batchId == batchID })

    // The timeline card was persisted by the real card-replacement path, and
    // its content proves provenance from the deterministic fake provider.
    let readWindow = Date().addingTimeInterval(-3600)...Date().addingTimeInterval(60)
    let cards = storage.fetchTimelineCardsByTimeRange(
      from: readWindow.lowerBound, to: readWindow.upperBound)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.title, EndToEndFakeProviderFactory.fakeCardTitle)
    XCTAssertEqual(cards.first?.category, "Work")
    XCTAssertEqual(cards.first?.batchId, batchID)

    // MARK: Engine façade reads — the new activity is visible through the
    // engine's existing read surface, backed by the same isolated storage.

    let activities = engine.activities(from: readWindow.lowerBound, to: readWindow.upperBound)
    XCTAssertEqual(activities.count, 1)
    XCTAssertEqual(activities.first?.title, EndToEndFakeProviderFactory.fakeCardTitle)

    let status = engine.processingStatus()
    XCTAssertEqual(
      status,
      ActivityProcessingStatus(
        analyzedBatchCount: 1, pendingBatchCount: 0, inFlightBatchCount: 0,
        failedBatchCount: 0))

    // NOTE (documented non-assertion): this fake-provider route intentionally
    // does not persist `llm_calls` rows (the service does not persist provider
    // logs per batch on this path), so no llm_calls assertion is made here.
  }
}
