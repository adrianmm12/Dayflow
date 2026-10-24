import GRDB
import XCTest

@testable import Dayflow

/// Isolation tests for `LLMLogger`'s injected-storage seam.
///
/// Each logger is constructed with an isolated `StorageManager` rooted at a
/// unique temporary directory; `StorageManager.shared` is never read or
/// written. No network, provider, or CLI execution occurs: the logger itself
/// is exercised directly (a pure persistence call).
///
/// Production wiring (verified structurally, not by touching production
/// storage): `LLMLogger.production` / the no-argument default resolves to
/// `StorageManager.shared`, and `LLMService`'s default provider construction
/// passes `LLMLogger(storage: <the service's storage>)` — `StorageManager.shared`
/// for `LLMService.shared`, identical to the original hard-wired behavior.
final class LLMLoggerIsolationTests: XCTestCase {
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
      .appendingPathComponent("dayflow-llm-logger-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return StorageManager(isolatedAt: root)
  }

  private func llmCallRows(in storage: StorageManager) -> [Row] {
    (try? storage.db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM llm_calls ORDER BY id ASC")
    }) ?? []
  }

  private func makeContext(startedAt: Date) -> LLMCallContext {
    LLMCallContext(
      batchId: 42,
      callGroupId: "group-1",
      attempt: 1,
      provider: "fake-provider",
      providerID: "fake-provider-id",
      model: "fake-model",
      operation: "transcribe",
      requestMethod: "POST",
      requestURL: URL(string: "https://example.test/v1/chat?key=supersecret&other=1"),
      requestHeaders: ["Authorization": "Bearer secret-token", "content-type": "application/json"],
      requestBody: Data("{\"prompt\": \"hi\"}".utf8),
      startedAt: startedAt)
  }

  // MARK: - Logger isolation

  /// A success log row lands in the injected store — with the logger's
  /// existing privacy behavior intact (query redaction, header dropping) —
  /// and a second injected store stays empty.
  func testLogSuccessWritesIntoInjectedStoreOnly() throws {
    let storageA = makeIsolatedStorage()
    let storageB = makeIsolatedStorage()
    let loggerA = LLMLogger(storage: storageA)
    _ = LLMLogger(storage: storageB)

    let startedAt = Date().addingTimeInterval(-1.5)
    loggerA.logSuccess(
      ctx: makeContext(startedAt: startedAt),
      http: LLMHTTPInfo(
        httpStatus: 200,
        responseHeaders: ["x-usage-output": "42"],
        responseBody: Data("{\"ok\": true}".utf8)),
      finishedAt: Date())

    let rowsA = llmCallRows(in: storageA)
    XCTAssertEqual(rowsA.count, 1)
    let row = try XCTUnwrap(rowsA.first)
    XCTAssertEqual(row["provider"] as String, "fake-provider")
    XCTAssertEqual(row["model"] as String, "fake-model")
    XCTAssertEqual(row["operation"] as String, "transcribe")
    XCTAssertEqual(row["status"] as String, "success")
    XCTAssertEqual(row["http_status"] as Int, 200)
    XCTAssertEqual(row["batch_id"] as Int64, 42)
    XCTAssertEqual(row["call_group_id"] as String, "group-1")
    let latencyMs = try XCTUnwrap(row["latency_ms"] as Int?)
    XCTAssertGreaterThanOrEqual(latencyMs, 1400)

    // Existing sanitization preserved: the API key in the URL query is
    // redacted (URLComponents percent-encodes the placeholder, hence
    // "redacted" rather than "<redacted>") and the Authorization header is
    // dropped.
    let requestURL = try XCTUnwrap(row["request_url"] as String?)
    XCTAssertTrue(requestURL.contains("redacted"))
    XCTAssertFalse(requestURL.contains("supersecret"))
    let requestHeaders = try XCTUnwrap(row["request_headers"] as String?)
    XCTAssertFalse(requestHeaders.contains("Authorization"))
    XCTAssertFalse(requestHeaders.contains("secret-token"))
    XCTAssertTrue(requestHeaders.contains("content-type"))
    // Response metadata persisted.
    XCTAssertTrue((row["response_body"] as String?)?.contains("ok") == true)

    // The second injected store saw nothing.
    XCTAssertTrue(llmCallRows(in: storageB).isEmpty)
  }

  /// A failure log row lands in the injected store with the raw error
  /// information, following the existing failure-record contract.
  func testLogFailureWritesIntoInjectedStore() throws {
    let storage = makeIsolatedStorage()
    let logger = LLMLogger(storage: storage)

    logger.logFailure(
      ctx: makeContext(startedAt: Date().addingTimeInterval(-0.25)),
      http: nil,
      finishedAt: Date(),
      errorDomain: "FakeErrorDomain",
      errorCode: 42,
      errorMessage: "fake failure message",
      failureStdout: nil,
      failureStderr: nil)

    let rows = llmCallRows(in: storage)
    XCTAssertEqual(rows.count, 1)
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(row["status"] as String, "failure")
    XCTAssertEqual(row["error_domain"] as String, "FakeErrorDomain")
    XCTAssertEqual(row["error_code"] as Int, 42)
    XCTAssertEqual(row["error_message"] as String, "fake failure message")
  }
}
