import XCTest

@testable import Dayflow

/// Minimal StorageManaging stub for RetryEligibility: every method except
/// `screenshotsForBatch` is unreachable from the retry-eligibility rule and
/// traps if called.
private final class RetryEligibilityStorageStub: StorageManaging {
  private let screenshotsByBatch: [Int64: [Screenshot]]

  init(screenshotsByBatch: [Int64: [Screenshot]] = [:]) {
    self.screenshotsByBatch = screenshotsByBatch
  }

  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot] {
    screenshotsByBatch[batchId] ?? []
  }

  func nextFileURL() -> URL { fatalError("unexpected call") }
  func registerChunk(url: URL) { fatalError("unexpected call") }
  func markChunkCompleted(url: URL) { fatalError("unexpected call") }
  func markChunkFailed(url: URL) { fatalError("unexpected call") }
  func fetchUnprocessedChunks(olderThan oldestAllowed: Int) -> [RecordingChunk] {
    fatalError("unexpected call")
  }
  func fetchChunksInTimeRange(startTs: Int, endTs: Int) -> [RecordingChunk] {
    fatalError("unexpected call")
  }
  func saveBatch(startTs: Int, endTs: Int, chunkIds: [Int64]) -> Int64? {
    fatalError("unexpected call")
  }
  func updateBatchStatus(batchId: Int64, status: String) { fatalError("unexpected call") }
  func updateBatch(_ batchId: Int64, status: String, reason: String?) {
    fatalError("unexpected call")
  }
  func checkpointPassive() { fatalError("unexpected call") }
  func checkpointTruncate() { fatalError("unexpected call") }
  func markBatchFailed(batchId: Int64, reason: String) { fatalError("unexpected call") }
  func updateBatchLLMMetadata(batchId: Int64, calls: [LLMCall]) { fatalError("unexpected call") }
  func fetchBatchLLMMetadata(batchId: Int64) -> [LLMCall] { fatalError("unexpected call") }
  func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64? {
    fatalError("unexpected call")
  }
  func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String) {
    fatalError("unexpected call")
  }
  func deleteTimelineCard(recordId: Int64) -> String? { fatalError("unexpected call") }
  func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard] {
    fatalError("unexpected call")
  }
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? {
    fatalError("unexpected call")
  }
  func fetchTimelineCardEndingLast(
    startingBefore: Date, excludingBatchId: Int64
  ) -> TimelineCardWithTimestamps? { fatalError("unexpected call") }
  func saveIdleBatchCard(
    _ card: TimelineCardShell, startTs: Int, endTs: Int, batchId: Int64, extendingCardId: Int64?
  ) -> (cardId: Int64?, deletedVideoPaths: [String]) { fatalError("unexpected call") }
  func replaceTimelineCardsInRange(
    from: Date, to: Date, with: [TimelineCardShell], batchId: Int64,
    keepingNewerBatchesCardsStartingAfter keepAfter: Date?
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) { fatalError("unexpected call") }
  func hasTimelineCardConnected(toBatchStartingAt batchStart: Date, maxGap: TimeInterval) -> Bool {
    fatalError("unexpected call")
  }
  func fetchTimelineCards(forDay day: String) -> [TimelineCard] { fatalError("unexpected call") }
  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard] {
    fatalError("unexpected call")
  }
  func fetchTotalMinutesTracked(from: Date, to: Date) -> Double { fatalError("unexpected call") }
  func fetchTotalMinutesTrackedForWeek(containing date: Date) -> Double {
    fatalError("unexpected call")
  }
  func replaceTimelineCardsInRange(
    from: Date, to: Date, with: [TimelineCardShell], batchId: Int64
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) { fatalError("unexpected call") }
  func fetchRecentTimelineCardsForDebug(limit: Int) -> [TimelineCardDebugEntry] {
    fatalError("unexpected call")
  }
  func updateTimelineCardCategory(cardId: Int64, category: String) {
    fatalError("unexpected call")
  }
  func updateTimelineCardTitle(cardId: Int64, title: String) { fatalError("unexpected call") }
  func fetchReviewRatingSegments(overlapping startTs: Int, endTs: Int)
    -> [TimelineReviewRatingSegment] { fatalError("unexpected call") }
  func applyReviewRating(startTs: Int, endTs: Int, rating: String) { fatalError("unexpected call") }
  func hasAnyTimelineReviewRating() -> Bool { fatalError("unexpected call") }
  func hasReviewRatingInRecentTimelineDays(days: Int) -> Bool { fatalError("unexpected call") }
  func fetchUnreviewedTimelineCardCount(forDay day: String, coverageThreshold: Double) -> Int {
    fatalError("unexpected call")
  }
  func fetchDayGoalPlan(forDay day: String) -> DayGoalPlan? { fatalError("unexpected call") }
  func fetchMostRecentDayGoalPlan(beforeOrOn day: String) -> DayGoalPlan? {
    fatalError("unexpected call")
  }
  func saveDayGoalPlan(_ plan: DayGoalPlan) { fatalError("unexpected call") }
  func fetchRecentLLMCallsForDebug(limit: Int) -> [LLMCallDebugEntry] {
    fatalError("unexpected call")
  }
  func fetchRecentAnalysisBatchesForDebug(limit: Int) -> [AnalysisBatchDebugEntry] {
    fatalError("unexpected call")
  }
  func fetchLLMCallsForBatches(batchIds: [Int64], limit: Int) -> [LLMCallDebugEntry] {
    fatalError("unexpected call")
  }
  func insertLLMCall(_ rec: LLMCallDBRecord) { fatalError("unexpected call") }
  func saveObservations(batchId: Int64, observations: [Observation]) {
    fatalError("unexpected call")
  }
  func fetchObservations(batchId: Int64) -> [Observation] { fatalError("unexpected call") }
  func fetchObservations(startTs: Int, endTs: Int) -> [Observation] {
    fatalError("unexpected call")
  }
  func fetchObservationsByTimeRange(from: Date, to: Date) -> [Observation] {
    fatalError("unexpected call")
  }
  func getTimestampsForVideoFiles(paths: [String]) -> [String: (startTs: Int, endTs: Int)] {
    fatalError("unexpected call")
  }
  func deleteTimelineCards(forDay day: String) -> [String] { fatalError("unexpected call") }
  func deleteTimelineCards(forBatchIds batchIds: [Int64]) -> [String] {
    fatalError("unexpected call")
  }
  func deleteObservations(forBatchIds batchIds: [Int64]) { fatalError("unexpected call") }
  func resetBatchStatuses(forDay day: String) -> [Int64] { fatalError("unexpected call") }
  func resetBatchStatuses(forBatchIds batchIds: [Int64]) -> [Int64] { fatalError("unexpected call") }
  func fetchBatches(forDay day: String) -> [(id: Int64, startTs: Int, endTs: Int, status: String)] {
    fatalError("unexpected call")
  }
  func chunksForBatch(_ batchId: Int64) -> [RecordingChunk] { fatalError("unexpected call") }
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
    fatalError("unexpected call")
  }
  func nextSegmentURL() -> URL { fatalError("unexpected call") }
  func saveScreenshot(
    segmentPath: String, frameIndex: Int, capturedAt: Date, idleSecondsAtCapture: Int?
  ) -> Int64? { fatalError("unexpected call") }
  func updateScreenshotFileSizes(segmentPath: String, totalBytes: Int64) {
    fatalError("unexpected call")
  }
  func markScreenshotsDeleted(segmentPath: String) { fatalError("unexpected call") }
  func mostRecentSegmentPath() -> String? { fatalError("unexpected call") }
  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot] {
    fatalError("unexpected call")
  }
  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64? {
    fatalError("unexpected call")
  }
  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot] {
    fatalError("unexpected call")
  }
}

final class RetryEligibilityTests: XCTestCase {
  private var existingFramePath: String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("retry-eligibility-frame-\(UUID().uuidString).jpg")
    FileManager.default.createFile(atPath: url.path, contents: Data([0xFF]))
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.path
  }

  private func makeCard(title: String, batchId: Int64?) -> TimelineCard {
    TimelineCard(
      recordId: nil,
      batchId: batchId,
      startTimestamp: "10:00 AM",
      endTimestamp: "10:15 AM",
      category: "System",
      subcategory: "Error",
      title: title,
      summary: "Your recording is saved.",
      detailedSummary: "",
      day: "2026-01-01",
      distractions: nil,
      videoSummaryURL: nil,
      otherVideoSummaryURLs: nil,
      appSites: nil
    )
  }

  private func makeScreenshot(id: Int64, filePath: String) -> Screenshot {
    Screenshot(
      id: id,
      capturedAt: 1_767_000_000,
      filePath: filePath,
      fileSize: nil,
      idleSecondsAtCapture: nil,
      isDeleted: false
    )
  }

  func testFailedCardWithAvailableScreenshotIsRetryable() {
    let storage = RetryEligibilityStorageStub(screenshotsByBatch: [
      42: [makeScreenshot(id: 1, filePath: existingFramePath)]
    ])

    XCTAssertTrue(
      RetryEligibility.isRetryableFailedCard(
        makeCard(title: "Processing failed", batchId: 42), storageManager: storage))
  }

  func testFailedCardWithoutBatchIdIsNotRetryable() {
    let storage = RetryEligibilityStorageStub(screenshotsByBatch: [
      42: [makeScreenshot(id: 1, filePath: existingFramePath)]
    ])

    XCTAssertFalse(
      RetryEligibility.isRetryableFailedCard(
        makeCard(title: "Processing failed", batchId: nil), storageManager: storage))
  }

  func testFailedCardWithoutAvailableScreenshotsIsNotRetryable() {
    let storage = RetryEligibilityStorageStub(screenshotsByBatch: [
      42: [
        makeScreenshot(id: 1, filePath: "/nonexistent/segment-1.mp4"),
        makeScreenshot(id: 2, filePath: "/nonexistent/segment-2.mp4"),
      ]
    ])

    XCTAssertFalse(
      RetryEligibility.isRetryableFailedCard(
        makeCard(title: "Processing failed", batchId: 42), storageManager: storage))
  }

  func testNonSentinelTitleIsNotRetryable() {
    let storage = RetryEligibilityStorageStub(screenshotsByBatch: [
      42: [makeScreenshot(id: 1, filePath: existingFramePath)]
    ])

    XCTAssertFalse(
      RetryEligibility.isRetryableFailedCard(
        makeCard(title: "Wrote documentation", batchId: 42), storageManager: storage))
  }

  func testTimelineActivityLoaderDelegatesToEngineRule() {
    let storage = RetryEligibilityStorageStub(screenshotsByBatch: [
      42: [makeScreenshot(id: 1, filePath: existingFramePath)]
    ])
    let retryableCard = makeCard(title: "Processing failed", batchId: 42)
    let notRetryableCard = makeCard(title: "Processing failed", batchId: 7)

    // The UI entry point must keep matching the engine-owned implementation.
    XCTAssertEqual(
      TimelineActivityLoader.isRetryableFailedCard(retryableCard, storageManager: storage),
      RetryEligibility.isRetryableFailedCard(retryableCard, storageManager: storage))
    XCTAssertEqual(
      TimelineActivityLoader.isRetryableFailedCard(notRetryableCard, storageManager: storage),
      RetryEligibility.isRetryableFailedCard(notRetryableCard, storageManager: storage))
  }
}
