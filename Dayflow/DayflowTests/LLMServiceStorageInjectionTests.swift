import GRDB
import XCTest

@testable import Dayflow

/// Storage-injection tests for the CONCRETE `LLMService`.
///
/// Each service is constructed with an isolated `StorageManager` rooted at a
/// unique temporary directory; `StorageManager.shared` is never touched. No
/// test reaches a real provider or the network: every exercised path
/// terminates at a pre-provider guard — either the batch-not-found early exit
/// or the no-screenshots throw that precedes any transcription/provider call.
/// (Provider construction may read local keychain/defaults; it never
/// performs network work, and inference is never invoked.)
final class LLMServiceStorageInjectionTests: XCTestCase {
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
      .appendingPathComponent("dayflow-llm-storage-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  /// Inserts one `analysis_batches` row (no screenshots) spanning five
  /// minutes from local noon of the given calendar day, inside the day's
  /// 4 AM window. Returns its id. Test-data arrangement only.
  @discardableResult
  private func insertScreenshotlessBatch(in storage: StorageManager, day: String = "2026-01-15")
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
        arguments: [startTs, startTs + 300])
      return db.lastInsertedRowID
    }
  }

  // MARK: - Construction

  /// A concrete service can be constructed against isolated storage with the
  /// production batching geometry intact.
  func testConcreteServiceConstructsAgainstInjectedStorage() {
    let service = LLMService(storage: makeIsolatedStorage())

    XCTAssertEqual(service.batchingConfig.targetDuration, BatchingConfig.standard.targetDuration)
    XCTAssertEqual(service.batchingConfig.maxGap, BatchingConfig.standard.maxGap)
    XCTAssertEqual(
      service.batchingConfig.cardLookbackDuration, BatchingConfig.standard.cardLookbackDuration)
  }

  // MARK: - Pre-provider paths

  /// The batch lookup consults the injected store: a nonexistent batch fails
  /// with the service's "Batch not found" error before any provider work.
  func testProcessBatchUnknownBatchFailsAgainstInjectedStore() {
    let service = LLMService(storage: makeIsolatedStorage())
    let completed = expectation(description: "processBatch completion")

    service.processBatch(999) { _ in } completion: { result in
      switch result {
      case .failure(let error):
        XCTAssertTrue(
          error.localizedDescription.contains("Batch not found"),
          "Expected the batch-not-found error, got: \(error)")
      case .success:
        XCTFail("Expected failure for an unknown batch")
      }
      completed.fulfill()
    }

    wait(for: [completed], timeout: 10.0)
  }

  /// The no-screenshots path — which throws before any transcription or
  /// provider/network call — performs every service-owned persistence
  /// operation against the injected store: the terminal "failed" batch
  /// status and the System/"Processing failed" error card.
  func testMissingScreenshotsFailurePersistsToInjectedStore() throws {
    let storage = makeIsolatedStorage()
    let service = LLMService(storage: storage)
    let batchID = try insertScreenshotlessBatch(in: storage)

    let completed = expectation(description: "processBatch completion")
    service.processBatch(batchID) { _ in } completion: { result in
      if case .success = result {
        XCTFail("Expected failure for a screenshot-less batch")
      }
      completed.fulfill()
    }
    wait(for: [completed], timeout: 10.0)

    // Service-owned terminal status write landed in the injected store.
    let batches = storage.allBatches()
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.status, "failed")

    // The error card was persisted to the injected store as well.
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dayDate = try XCTUnwrap(formatter.date(from: "2026-01-15"))
    let noon = try XCTUnwrap(
      Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate))
    let cards = storage.fetchTimelineCardsByTimeRange(
      from: noon.addingTimeInterval(-3600), to: noon.addingTimeInterval(3600))
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.category, "System")
    XCTAssertEqual(cards.first?.title, "Processing failed")
    XCTAssertEqual(cards.first?.batchId, batchID)
  }

  /// Two services on separate isolated stores do not share data: each
  /// service's failure path persists only to its own store.
  func testTwoServicesUseSeparateInjectedStores() throws {
    let storageA = makeIsolatedStorage()
    let serviceA = LLMService(storage: storageA)
    let batchA = try insertScreenshotlessBatch(in: storageA)
    let storageB = makeIsolatedStorage()
    let serviceB = LLMService(storage: storageB)
    _ = try insertScreenshotlessBatch(in: storageB)

    let completedA = expectation(description: "serviceA completion")
    serviceA.processBatch(batchA) { _ in } completion: { _ in
      completedA.fulfill()
    }
    wait(for: [completedA], timeout: 10.0)

    // A's failure wrote only to A's store: B's store still has its seeded,
    // untouched pending batch and no error cards.
    XCTAssertEqual(storageA.allBatches().first?.status, "failed")
    XCTAssertEqual(storageB.allBatches().first?.status, "pending")
    XCTAssertTrue(
      storageB.fetchTimelineCardsByTimeRange(from: .distantPast, to: .distantFuture).isEmpty)

    // B's service failure likewise persists only to B's store.
    let batchB = try XCTUnwrap(storageB.allBatches().first?.id)
    let completedB = expectation(description: "serviceB completion")
    serviceB.processBatch(batchB) { _ in } completion: { _ in
      completedB.fulfill()
    }
    wait(for: [completedB], timeout: 10.0)

    XCTAssertEqual(storageB.allBatches().first?.status, "failed")
    XCTAssertEqual(
      storageB.fetchTimelineCardsByTimeRange(from: .distantPast, to: .distantFuture).count, 1)
    // A's store is unchanged by B's run: still exactly one error card.
    XCTAssertEqual(
      storageA.fetchTimelineCardsByTimeRange(from: .distantPast, to: .distantFuture).count, 1)
  }
}
