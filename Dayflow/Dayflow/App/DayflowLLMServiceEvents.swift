//
//  DayflowLLMServiceEvents.swift
//  Dayflow
//
//  The Dayflow app's implementation of the engine-owned LLMServiceEvents
//  seam (Core/AI/LLMServiceEvents.swift). Forwards analysis lifecycle
//  events to the existing product surfaces: the timeline failure toast
//  and the getting-started first-cards milestone.
//

import Foundation

final class DayflowLLMServiceEvents: LLMServiceEvents {
  func analysisFailureNeedsUserAttention(_ payload: TimelineFailureToastPayload) {
    TimelineFailureToastCenter.post(payload)
  }

  func analysisFailureRecovered() {
    TimelineFailureToastCenter.hide()
  }

  func batchAnalyzed(cardCount: Int) {
    Task { @MainActor in
      GettingStarted.handleBatchAnalyzed(cardCount: cardCount)
    }
  }
}
