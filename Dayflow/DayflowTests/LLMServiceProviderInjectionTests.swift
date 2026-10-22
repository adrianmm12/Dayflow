import GRDB
import XCTest

@testable import Dayflow

/// Provider-execution injection tests for the CONCRETE `LLMService`.
///
/// An injected `providerContextFor` factory replaces only provider EXECUTION
/// (the transcription / card-generation closures `processBatch` invokes);
/// routing — deciding which provider — still runs through the real
/// `LLMProviderRoutingStore`, so the test works regardless of which provider
/// the machine has configured. The fake never touches network, CLI,
/// keychain, or `LLMLogger` (which would write to `StorageManager.shared`),
/// and all service-owned orchestration — batch lookup, status writes,
/// screenshot reads, observation persistence, card generation context,
/// card replacement, terminal status, passive checkpoint, completion — is
/// the REAL `LLMService` running against the injected isolated store.
final class LLMServiceProviderInjectionTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  // MARK: - Fake provider execution

  /// Deterministic fake provider: returns fixed observations and one activity
  /// card per invocation, derived from the batch window. Records which
  /// provider IDs the service asked it to construct.
  private final class FakeProviderFactory {
    private let lock = NSLock()
    private var _requestedProviderIDs: [LLMProviderID] = []
    private var _transcriptionCallCount = 0
    private var _cardGenerationCallCount = 0

    var requestedProviderIDs: [LLMProviderID] {
      lock.withLock { _requestedProviderIDs }
    }
    var transcriptionCallCount: Int {
      lock.withLock { _transcriptionCallCount }
    }
    var cardGenerationCallCount: Int {
      lock.withLock { _cardGenerationCallCount }
    }

    private func recordTranscription() {
      lock.withLock { _transcriptionCallCount += 1 }
    }
    private func recordCardGeneration() {
      lock.withLock { _cardGenerationCallCount += 1 }
    }

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
          self?.recordTranscription()
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
          self?.recordCardGeneration()
          // One card inside the batch window, derived from the window's
          // current time so the service's clock-string parsing lands it in
          // the replacement range.
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

  // MARK: - Isolated storage helpers

  private func makeIsolatedStorage() -> StorageManager {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-llm-provider-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// One pending 12-minute batch with three joined, non-idle screenshots.
  @discardableResult
  private func seedBatchWithScreenshots(in storage: StorageManager, day: String = "2026-01-15")
    throws -> Int64
  {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: day))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let startTs = Int(noon.timeIntervalSince1970)

    return try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts, status) VALUES (?, ?, 'pending')",
        arguments: [startTs, startTs + 720])
      let batchId = db.lastInsertedRowID
      for offset in [0, 300, 600] {
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

  // MARK: - Success path through the real service orchestration

  /// The complete success path: real `processBatch` orchestration (batch
  /// lookup, status writes, screenshot reads, observation persistence,
  /// card-generation context, card replacement, terminal status, passive
  /// checkpoint, completion) with fake provider execution and an isolated
  /// store. No network, CLI, keychain, or production storage is reachable.
  func testProcessBatchSuccessPathRunsRealOrchestrationAgainstFakeProviderAndInjectedStore()
    throws
  {
    let storage = makeIsolatedStorage()
    let fake = FakeProviderFactory()
    let service = LLMService(storage: storage, providerContextFor: fake.providerContext(for:))
    let batchID = try seedBatchWithScreenshots(in: storage)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: "2026-01-15"))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))

    // The storage-level activity-change signal fires through the real card
    // replacement mutation path.
    let signalReceived = expectation(description: "activity change signal")
    let token = NotificationCenter.default.addObserver(
      forName: .timelineActivitiesChanged, object: nil, queue: nil
    ) { _ in
      signalReceived.fulfill()
    }
    addTeardownBlock { NotificationCenter.default.removeObserver(token) }

    let completed = expectation(description: "processBatch completion")
    var completionResult: Result<ProcessedBatchResult, Error>?
    service.processBatch(batchID) { _ in } completion: { result in
      completionResult = result
      completed.fulfill()
    }
    wait(for: [completed], timeout: 20.0)
    wait(for: [signalReceived], timeout: 5.0)

    // The service asked the injected factory for the routing-chosen
    // provider's execution context (once; backup contexts only when routed).
    XCTAssertFalse(fake.requestedProviderIDs.isEmpty)

    // Both inference stages ran through the fake — no real provider was
    // constructed or contacted.
    XCTAssertEqual(fake.transcriptionCallCount, 1)
    XCTAssertEqual(fake.cardGenerationCallCount, 1)

    // Completion carries the production result shape.
    let result = try XCTUnwrap(completionResult)
    let value: ProcessedBatchResult
    switch result {
    case .success(let processed):
      value = processed
    case .failure(let error):
      XCTFail("Expected success, got: \(error)")
      return
    }
    XCTAssertEqual(value.cards.count, 1)
    XCTAssertEqual(value.cardIds.count, 1)

    // Observations were persisted by the real service into the injected store.
    let observations = storage.fetchObservations(batchId: batchID)
    XCTAssertEqual(observations.count, 2)
    XCTAssertTrue(observations.allSatisfy { $0.observation == FakeProviderFactory.fakeObservationText })
    XCTAssertTrue(observations.allSatisfy { $0.llmModel == FakeProviderFactory.fakeModel })

    // The timeline card was persisted by the real card-replacement path.
    let cards = storage.fetchTimelineCardsByTimeRange(
      from: noon.addingTimeInterval(-3600), to: noon.addingTimeInterval(3600))
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.title, FakeProviderFactory.fakeCardTitle)
    XCTAssertEqual(cards.first?.category, "Work")
    XCTAssertEqual(cards.first?.batchId, batchID)

    // The batch reached its successful terminal status in the injected store.
    XCTAssertEqual(storage.allBatches().first?.status, "analyzed")
  }

  /// Two services with separate injected stores and separate fakes stay
  /// isolated: a successful run through one leaves the other's store empty.
  func testSuccessPathDoesNotLeakIntoSecondInjectedStore() throws {
    let storageA = makeIsolatedStorage()
    let fakeA = FakeProviderFactory()
    let serviceA = LLMService(storage: storageA, providerContextFor: fakeA.providerContext(for:))
    let batchA = try seedBatchWithScreenshots(in: storageA)
    let storageB = makeIsolatedStorage()
    let fakeB = FakeProviderFactory()
    let serviceB = LLMService(storage: storageB, providerContextFor: fakeB.providerContext(for:))

    let completed = expectation(description: "processBatch completion")
    serviceA.processBatch(batchA) { _ in } completion: { _ in
      completed.fulfill()
    }
    wait(for: [completed], timeout: 20.0)

    XCTAssertEqual(storageA.allBatches().first?.status, "analyzed")
    XCTAssertEqual(storageA.fetchTimelineCardsByTimeRange(from: .distantPast, to: .distantFuture).count, 1)
    // B's service was never invoked and B's store is untouched.
    XCTAssertTrue(fakeB.requestedProviderIDs.isEmpty)
    XCTAssertEqual(storageB.fetchTimelineCardsByTimeRange(from: .distantPast, to: .distantFuture).count, 0)
    XCTAssertTrue(storageB.fetchObservations(batchId: batchA).isEmpty)
  }
}
