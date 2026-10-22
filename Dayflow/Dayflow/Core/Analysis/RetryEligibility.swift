//
//  RetryEligibility.swift
//  Dayflow
//
//  Engine-owned rule for deciding which failed timeline cards can be retried.
//  Moved verbatim from TimelineActivityLoader so the analysis pipeline does
//  not depend on UI-layer code; the UI delegates back to this implementation.
//

import Foundation

enum RetryEligibility {
  // Stored card titles are always the English sentinel, regardless of UI language.
  static let failedCardTitle = "Processing failed"

  /// A failed card is retryable when it is the failure sentinel, is tied to a
  /// batch, and that batch still has at least one screenshot whose backing
  /// file exists on disk.
  static func isRetryableFailedCard(_ card: TimelineCard, storageManager: StorageManaging)
    -> Bool
  {
    guard card.title == failedCardTitle, let batchId = card.batchId else { return false }
    return hasRetrySourceScreenshots(for: batchId, storageManager: storageManager)
  }

  private static func hasRetrySourceScreenshots(
    for batchId: Int64,
    storageManager: StorageManaging
  ) -> Bool {
    storageManager.screenshotsForBatch(batchId).contains(where: \.isAvailable)
  }
}
