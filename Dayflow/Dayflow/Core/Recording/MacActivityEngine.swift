//
//  MacActivityEngine.swift
//  Dayflow
//
//  Engine-owned lifecycle coordinator for the Mac activity engine. Owns the
//  responsibilities AppDelegate previously performed inline: retaining the
//  ScreenRecorder, starting the analysis background job, and flushing storage
//  state on termination.
//
//  Recording on/off control is unchanged: the recorder still observes
//  AppState.shared.isRecording directly, and the host app still drives that
//  flag. The recorder itself owns capture timers, sleep/wake/lock/screensaver
//  handling, ScreenCaptureKit failure retries, and finalizing the open
//  capture segment on app termination; none of that is duplicated here.
//

import Foundation

@MainActor
final class MacActivityEngine {
  /// Retained for the engine's lifetime so the recorder keeps observing
  /// system events and AppState until shutdown.
  private var recorder: ScreenRecorder?

  /// Seeds the recording flag low, then constructs the recorder so the first
  /// transition to true will reliably start capture.
  ///
  /// Must run before the host enables AppState persistence or restores the
  /// saved recording preference: seeding after persistence is enabled would
  /// overwrite the saved preference with `false`. Constructing the recorder
  /// also runs FrameStore's launch reconciliation, which is the engine's first
  /// touch of the shared storage database.
  func start() {
    AppState.shared.isRecording = false
    recorder = ScreenRecorder(autoStart: true)
  }

  /// Starts the provider-routed analysis background job. Moved verbatim from
  /// AppDelegate.setupTimelineAnalysis(); the short delay lets other launch
  /// initialization complete first. The host must install its LLMService
  /// event sink before calling this.
  func startAnalysisJob() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      AnalysisManager.shared.startAnalysisJob()
      print("AppDelegate: LLM analysis job started")
      let providerID = (try? LLMProviderRoutingStore.load())?.primary
      AnalyticsService.shared.capture(
        "analysis_job_started",
        [
          "provider": providerID?.analyticsName ?? "unknown",
          "provider_id": providerID?.rawValue ?? "unknown",
        ])
    }
  }

  /// Flushes engine storage state during application termination by
  /// checkpointing (and truncating) the database WAL. The open capture
  /// segment is finalized separately by the recorder's own will-terminate
  /// observer (FrameStore.finishCurrentSegment()).
  func shutdown() {
    StorageManager.shared.checkpoint(mode: .truncate)
  }

  // MARK: - Read-only timeline activity access

  /// The persisted timeline cards whose time overlaps the given range, oldest
  /// first, exactly as storage returns them: no category filtering (System /
  /// "Processing failed" cards are included) and soft-deleted cards are
  /// excluded. Reads the shared storage database synchronously.
  ///
  /// Recent-activity queries compose naturally:
  /// `activities(from: Date().addingTimeInterval(-lookback), to: Date())`.
  func activities(from: Date, to: Date) -> [TimelineCard] {
    StorageManager.shared.fetchTimelineCardsByTimeRange(from: from, to: to)
  }

  // MARK: - Reprocessing

  /// Re-processes one logical day's captured activity through the analysis
  /// machinery, using Dayflow's existing day-level reprocessing semantics.
  ///
  /// The day is a `yyyy-MM-dd` logical-day string under the app's 4 AM
  /// boundary (`Date().getDayInfoFor4AMBoundary().dayString`). Reprocessing
  /// deletes that day's timeline cards (and their timelapse files), deletes
  /// its observations, resets the day's batches to pending, and re-runs each
  /// batch sequentially through the provider pipeline. Progress messages and
  /// the completion result are delivered on the main thread.
  func reprocessDay(
    _ day: String,
    progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    AnalysisManager.shared.reprocessDay(
      day, progressHandler: progressHandler, completion: completion)
  }

  // MARK: - Processing status

  /// A read-only, point-in-time snapshot of the analysis pipeline's state.
  ///
  /// Persisted batch statuses are read from the storage database. The
  /// in-flight count comes from the analysis manager's in-memory tracker,
  /// which is authoritative for "executing right now": a persisted
  /// "processing" status can be left behind by a mid-run quit, so it is not
  /// reported as active work (such batches are retried automatically).
  ///
  /// The counts are point-in-time per source and not mutually atomic: a
  /// batch transitioning between states can momentarily appear in, or be
  /// missing from, one count. Terminal no-output outcomes (`failed_empty`,
  /// `skipped_short`) are neither success nor failure here.
  func processingStatus() -> ActivityProcessingStatus {
    let batches = StorageManager.shared.allBatches()
    return ActivityProcessingStatus(
      analyzedBatchCount: batches.filter { ActivityProcessingStatus.isSuccessStatus($0.status) }
        .count,
      pendingBatchCount: batches.filter { $0.status == "pending" }.count,
      inFlightBatchCount: AnalysisManager.shared.inFlightBatchCount,
      failedBatchCount: batches.filter { $0.status == "failed" }.count
    )
  }

  // MARK: - Capture control

  /// Requests screen capture to start. Delegates to the app's canonical
  /// recording-state mutation (AppState.setRecording), which the screen
  /// recorder observes through its existing subscription. Like the manual
  /// recording toggle, the preference persists and is restored on launch.
  ///
  /// Permission UX is host-owned, not part of this call: if the
  /// screen-recording permission is missing, the recorder's existing
  /// machinery turns recording back off (without persisting that
  /// correction), and posts the screen-recording permission notice for the
  /// host to surface.
  func startCapture() {
    AppState.shared.setRecording(true, analyticsReason: "engine")
  }

  /// Requests screen capture to stop. Delegates to the canonical
  /// recording-state mutation; the preference persists, matching the manual
  /// toggle's semantics.
  func stopCapture() {
    AppState.shared.setRecording(false, analyticsReason: "engine")
  }

  /// Whether the recording-control flag is currently enabled: a read-only
  /// mirror of the state the recorder observes. This is not an
  /// instantaneous capture sensor — the recorder pauses during sleep/lock
  /// while this flag stays true.
  var isCaptureEnabled: Bool {
    AppState.shared.isRecording
  }
}

/// The engine façade's activity-change surface: re-exposes the storage
/// layer's engine-owned timeline-activity signal so higher-level callers
/// observe through the engine without knowing which storage component emits
/// it. Top-level (not MainActor-isolated) so observation works from any
/// execution context, headless included.
enum MacActivityEngineSignals {
  /// The activity-change signal: posted after a timeline-card persistence
  /// mutation commits. Coarse re-read invalidation — no payload. The signal
  /// is posted on the mutating thread; pass a `queue` when observing if a
  /// specific delivery context is required.
  static let activityChangedNotification = Notification.Name.timelineActivitiesChanged

  /// Observes the engine's activity-change signal.
  ///
  /// The returned token follows NotificationCenter rules: deliver it to
  /// `NotificationCenter.default.removeObserver(_:)` to stop observing.
  @discardableResult
  static func observeActivityChanges(
    queue: OperationQueue? = nil,
    using handler: @escaping (Notification) -> Void
  ) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: activityChangedNotification, object: nil, queue: queue, using: handler)
  }
}

/// Machine-readable snapshot of the analysis pipeline's processing state.
/// Engine-owned and presentation-free: counts of persisted batch statuses
/// plus the live in-flight tracker. Human progress strings and UI state are
/// deliberately not part of this model.
struct ActivityProcessingStatus: Sendable, Equatable {
  /// Batches that finished analyzing successfully. Both persisted spellings
  /// count: `analyzed` (written by the provider pipeline) and `completed`
  /// (written by the analysis completion handler) are the same outcome.
  let analyzedBatchCount: Int

  /// Batches queued but not yet running, including batches reset for
  /// reprocessing (persisted status `pending`).
  let pendingBatchCount: Int

  /// Batches whose LLM processing is executing right now.
  let inFlightBatchCount: Int

  /// Batches in persisted terminal-failure status (`failed`).
  let failedBatchCount: Int

  /// Whether any inference work is executing right now.
  var isAnalyzing: Bool { inFlightBatchCount > 0 }

  /// Read-only normalization of the two terminal-success spellings. This
  /// interprets persisted values; it never rewrites or migrates them.
  static func isSuccessStatus(_ status: String) -> Bool {
    status == "analyzed" || status == "completed"
  }
}
