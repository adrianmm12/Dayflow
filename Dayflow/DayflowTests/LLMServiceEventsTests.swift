import XCTest

@testable import Dayflow

/// Focused tests for the LLMServiceEvents seam: hook invocation through
/// LLMService.eventSink, the headless nil configuration, and installed-sink
/// replacement.
///
/// The headless host installs no sink; every test saves and restores the
/// previous sink.
final class LLMServiceEventsTests: XCTestCase {
  private final class RecordingEvents: LLMServiceEvents {
    var failurePayloads: [TimelineFailureToastPayload] = []
    var recoveredCount = 0
    var analyzedCardCounts: [Int] = []

    func analysisFailureNeedsUserAttention(_ payload: TimelineFailureToastPayload) {
      failurePayloads.append(payload)
    }

    func analysisFailureRecovered() {
      recoveredCount += 1
    }

    func batchAnalyzed(cardCount: Int) {
      analyzedCardCounts.append(cardCount)
    }
  }

  private func withSink(_ sink: (any LLMServiceEvents)?, body: () throws -> Void) rethrows {
    let previous = LLMService.eventSink
    LLMService.eventSink = sink
    defer { LLMService.eventSink = previous }
    try body()
  }

  private func makePayload() -> TimelineFailureToastPayload {
    TimelineFailureToastPayload(
      message: "Fix the provider",
      title: nil,
      providerName: "openai_compatible",
      steps: ["Add the API key"],
      command: nil,
      waitingSeconds: 900,
      destination: .providers,
      failureKind: TimelineFailureKind.apiKeyProblem.rawValue,
      operation: "generate_cards",
      primaryProvider: "openai_compatible",
      primaryProviderLabel: "openai_compatible",
      backupProvider: nil,
      backupProviderLabel: nil,
      backupConfigured: false,
      rateLimitDetected: false,
      errorDomain: "OpenAICompatibleProvider",
      errorCode: 1,
      batchId: 42
    )
  }

  func testNilSinkIsSilentNoOp() {
    withSink(nil) {
      LLMService.eventSink?.analysisFailureNeedsUserAttention(makePayload())
      LLMService.eventSink?.analysisFailureRecovered()
      LLMService.eventSink?.batchAnalyzed(cardCount: 3)
    }
    // Headless default: no crash, no event delivered anywhere.
  }

  func testInstalledSinkReceivesEvents() {
    let recorder = RecordingEvents()
    withSink(recorder) {
      LLMService.eventSink?.analysisFailureNeedsUserAttention(makePayload())
      LLMService.eventSink?.analysisFailureRecovered()
      LLMService.eventSink?.batchAnalyzed(cardCount: 5)
    }

    XCTAssertEqual(recorder.failurePayloads.count, 1)
    XCTAssertEqual(recorder.failurePayloads.first?.batchId, 42)
    XCTAssertEqual(recorder.recoveredCount, 1)
    XCTAssertEqual(recorder.analyzedCardCounts, [5])
  }

  func testInstalledSinkCanBeReplaced() {
    let first = RecordingEvents()
    let second = RecordingEvents()
    withSink(first) {
      LLMService.eventSink?.analysisFailureRecovered()
      LLMService.eventSink = second
      LLMService.eventSink?.analysisFailureRecovered()
    }

    XCTAssertEqual(first.recoveredCount, 1)
    XCTAssertEqual(second.recoveredCount, 1)
  }
}
