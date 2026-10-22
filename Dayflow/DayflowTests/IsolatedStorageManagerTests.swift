import GRDB
import XCTest

@testable import Dayflow

/// Isolated-construction tests for `StorageManager`.
///
/// Every instance is rooted at a unique temporary directory via
/// `StorageManager(isolatedAt:)`. `StorageManager.shared` is never constructed or
/// touched here, so none of these tests can read, migrate, or mutate real Dayflow
/// data. The production path is only ever *computed* for inequality assertions.
final class IsolatedStorageManagerTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-isolated-storage-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeStorage() -> StorageManager {
    StorageManager(isolatedAt: makeTempRoot())
  }

  /// The real production base directory, computed the same way the production
  /// configuration does. Used only for path *inequality* assertions; nothing is
  /// ever constructed or opened against it.
  private var productionBaseDirectory: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow", isDirectory: true)
  }

  /// Inserts one `chunks` row directly, returning its id. Used to satisfy the
  /// `batch_chunks` foreign key (GRDB enables foreign keys by default) before
  /// calling the existing `saveBatch` API.
  private func insertChunkRow(in storage: StorageManager) throws -> Int64 {
    try storage.db.write { db in
      try db.execute(
        sql: "INSERT INTO chunks(start_ts, end_ts, file_url, status) VALUES (?, ?, ?, 'recording')",
        arguments: [100, 160, "/nonexistent/chunk.mp4"])
      return db.lastInsertedRowID
    }
  }

  func testIsolatedManagerCreatesAndOpensDatabaseUnderSuppliedDirectory() {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)

    XCTAssertEqual(storage.dbURL, root.appendingPathComponent("chunks.sqlite"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: storage.dbURL.path))

    // Isolated equivalents of every other owned filesystem location exist under
    // the supplied temporary root.
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("recordings").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
  }

  func testIsolatedManagerDoesNotUseProductionPaths() {
    let storage = makeStorage()
    let productionBase = productionBaseDirectory.path

    XCTAssertNotEqual(storage.dbURL.path, productionBaseDirectory.appendingPathComponent("chunks.sqlite").path)
    XCTAssertFalse(storage.dbURL.path.hasPrefix(productionBase))
    XCTAssertFalse(storage.root.path.hasPrefix(productionBase))
    XCTAssertFalse(storage.backupsDir.path.hasPrefix(productionBase))
  }

  func testIsolatedManagerCreatesCoreSchema() throws {
    let storage = makeStorage()

    let tables = try storage.db.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }

    let expectedTables = [
      "chunks", "analysis_batches", "batch_chunks", "timeline_cards",
      "timeline_review_ratings", "observations", "screenshots", "batch_screenshots",
      "journal_entries", "daily_standup_entries", "day_goals", "day_goal_categories",
      "llm_calls", "chat_conversations", "chat_messages",
    ]
    for expected in expectedTables {
      XCTAssertTrue(tables.contains(expected), "missing core table: \(expected)")
    }
  }

  func testTwoIsolatedManagersRootedSeparatelyDoNotShareData() throws {
    let storageA = makeStorage()
    let storageB = makeStorage()

    let chunkID = try insertChunkRow(in: storageA)
    let batchID = try XCTUnwrap(storageA.saveBatch(startTs: 100, endTs: 200, chunkIds: [chunkID]))
    let batchesA = storageA.allBatches()
    XCTAssertEqual(batchesA.count, 1)
    XCTAssertEqual(batchesA.first?.id, batchID)
    XCTAssertEqual(batchesA.first?.status, "pending")

    XCTAssertTrue(storageB.allBatches().isEmpty)
  }

  func testBatchRoundTripPersistsToDiskUnderSuppliedDirectory() throws {
    let root = makeTempRoot()

    // First instance writes a batch.
    let writer = StorageManager(isolatedAt: root)
    let chunkID = try insertChunkRow(in: writer)
    let batchID = try XCTUnwrap(writer.saveBatch(startTs: 1_000, endTs: 2_000, chunkIds: [chunkID]))
    XCTAssertEqual(writer.allBatches().count, 1)

    // A second instance rooted at the same directory reads it back.
    let reader = StorageManager(isolatedAt: root)
    let batches = reader.allBatches()
    XCTAssertEqual(batches.count, 1)
    XCTAssertEqual(batches.first?.id, batchID)
    XCTAssertEqual(batches.first?.start, 1_000)
    XCTAssertEqual(batches.first?.end, 2_000)
    XCTAssertEqual(batches.first?.status, "pending")
  }
}
