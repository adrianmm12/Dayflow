//
//  MacActivityEngine.swift
//  Dayflow
//
//  Engine-owned lifecycle coordinator for the Mac activity engine. Owns the
//  responsibilities AppDelegate previously performed inline: retaining the
//  ScreenRecorder, starting the analysis background job, and flushing storage
//  state on termination.
//
//  Recording on/off control flows through the engine-owned RecordingState,
//  which the recorder observes directly. The host app (or this façade's
//  capture-control methods) drives that state.
//

import Foundation

@MainActor
final class MacActivityEngine {
  /// Retained for the engine's lifetime so the recorder keeps observing
  /// system events and RecordingState until shutdown.
  private var recorder: ScreenRecorder?

  /// Storage backing the engine's directly-owned façade operations: the
  /// timeline-card range query in `activities(from:to:)`, the persisted
  /// batch counts in `processingStatus()`, and the truncate checkpoint in
  /// `shutdown()`. Production constructs the engine with no arguments and
  /// gets the shared storage database; tests and future engine hosts inject an
  /// isolated `StorageManager`.
  ///
  /// Analysis behavior (`startAnalysisJob()`, `reprocessDay(...)`, and the
  /// in-flight count in `processingStatus()`) is backed by the injected
  /// `analysis` dependency below; an engine composed with isolated storage
  /// AND an isolated analysis manager is coherent across both. Every
  /// non-capture façade operation honors the injected dependencies.
  private let storage: any StorageManaging

  /// Analysis backing the engine's analysis-facing façade operations:
  /// scheduler startup, day reprocessing, and the in-flight count in
  /// `processingStatus()`. Production defaults to the shared manager; tests
  /// and future engine hosts inject an `AnalysisManaging` instance (e.g. an
  /// `AnalysisManager` wired to the same isolated storage and a fake
  /// `LLMServicing`).
  private let analysis: any AnalysisManaging

  /// The recording-control state the engine's capture façade drives and the
  /// recorder observes. Production defaults to the shared state; tests and
  /// future engine hosts inject an isolated `RecordingState` so
  /// `startCapture()`/`stopCapture()`/`isCaptureEnabled` and the constructed
  /// recorder stay coherent on ONE state object instead of meeting by
  /// accident via the singleton.
  private let recordingState: RecordingState

  /// Constructs the recorder when `start()` runs. Receives the engine's own
  /// `recordingState` so the recorder can never observe a different state
  /// than the capture façade drives — in production AND in isolated
  /// compositions. Kept as the same lifecycle point (inside `start()`, not
  /// the initializer); the closure is instance-owned and immutable after
  /// construction.
  private let makeRecorder: @MainActor (RecordingState) -> ScreenRecorder

  /// All parameters default to the shared production singletons;
  /// `MacActivityEngine()` therefore continues to resolve to
  /// `StorageManager.shared` + `AnalysisManager.shared` +
  /// `RecordingState.shared` + the real `ScreenRecorder` factory with no
  /// call-site changes.
  init(
    storage: any StorageManaging = StorageManager.shared,
    analysis: any AnalysisManaging = AnalysisManager.shared,
    recordingState: RecordingState = .shared,
    makeRecorder: @MainActor @escaping (RecordingState) -> ScreenRecorder = { state in
      ScreenRecorder(autoStart: true, recordingState: state)
    }
  ) {
    self.storage = storage
    self.analysis = analysis
    self.recordingState = recordingState
    self.makeRecorder = makeRecorder
  }

  /// Seeds the recording flag low, then constructs the recorder so the first
  /// transition to true will reliably start capture.
  ///
  /// Must run before the host enables RecordingState persistence or restores
  /// the saved recording preference: seeding after persistence is enabled would
  /// overwrite the saved preference with `false`. Constructing the recorder
  /// also runs FrameStore's launch reconciliation, which is the engine's first
  /// touch of the shared storage database.
  func start() {
    recordingState.isRecording = false
    recorder = makeRecorder(recordingState)
  }

  /// Starts the provider-routed analysis background job. Moved verbatim from
  /// AppDelegate.setupTimelineAnalysis(); the short delay lets other launch
  /// initialization complete first. The host must install its LLMService
  /// event sink before calling this.
  func startAnalysisJob() {
    // Capture the injected dependency directly (not self): the delayed start
    // must fire even if this engine instance is deallocated within the delay,
    // exactly as the previous singleton call behaved.
    let analysis = self.analysis
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      analysis.startAnalysisJob()
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
  /// checkpointing (and truncating) the storage WAL — but only AFTER the
  /// engine-owned recorder has deterministically finished its capture work.
  ///
  /// Ordering guarantee (replaces the previous reliance on the recorder's
  /// independent `NSApplication.willTerminate` observer, whose delivery
  /// order relative to this call was unspecified):
  ///
  /// ```text
  /// owned ScreenRecorder stops capture            (synchronous, on its queue)
  ///   → its FrameStore's open segment finalizes  (synchronous, write queue)
  ///   → final segment metadata/file-size DB writes commit
  ///   → injected storage.checkpointTruncate() runs
  ///   → shutdown returns
  /// ```
  ///
  /// `stopAndWait()` drains the recorder's serial queue before performing the
  /// stop, so every earlier recorder write (screenshot rows, segment
  /// finalization, file sizes) happens-before the truncate checkpoint. The
  /// injected storage is flushed exactly as before: production wiring resolves
  /// to `StorageManager.shared`'s truncate checkpoint, and an engine composed
  /// with isolated storage flushes only that isolated database.
  ///
  /// The recorder's runtime capture state and the user's persisted recording
  /// preference are deliberately untouched: this stops the owned recorder
  /// directly (bypassing RecordingState), so a user who was recording when
  /// they quit still has their "recording on" preference for the next launch.
  ///
  /// Repeated calls are harmless: the stop work is nil-safe and finalization
  /// is idempotent, and the truncate checkpoint can repeat. The recorder's
  /// `willTerminate` observer remains as a compatibility fallback; after this
  /// path has finalized the segment it is a no-op.
  func shutdown() {
    recorder?.stopAndWait()
    storage.checkpointTruncate()
  }

  // MARK: - Read-only timeline activity access

  /// The persisted timeline cards whose time overlaps the given range, oldest
  /// first, exactly as the engine's storage returns them: no category
  /// filtering (System / "Processing failed" cards are included) and
  /// soft-deleted cards are excluded. Reads the storage synchronously (the
  /// shared production database unless the engine was constructed with
  /// isolated storage).
  ///
  /// Recent-activity queries compose naturally:
  /// `activities(from: Date().addingTimeInterval(-lookback), to: Date())`.
  func activities(from: Date, to: Date) -> [TimelineCard] {
    storage.fetchTimelineCardsByTimeRange(from: from, to: to)
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
  ///
  /// Delegates to the engine's injected analysis dependency: an engine
  /// composed with isolated storage + an isolated analysis manager reprocesses
  /// entirely through those dependencies.
  func reprocessDay(
    _ day: String,
    progressHandler: @escaping (String) -> Void,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    analysis.reprocessDay(
      day, progressHandler: progressHandler, completion: completion)
  }

  // MARK: - Processing status

  /// A read-only, point-in-time snapshot of the analysis pipeline's state.
  ///
  /// Persisted batch statuses are read from the engine's storage and the
  /// in-flight count from the engine's injected analysis dependency, which is
  /// authoritative for "executing right now": a persisted "processing" status
  /// can be left behind by a mid-run quit, so it is not reported as active
  /// work (such batches are retried automatically). With production wiring
  /// both come from the shared singletons; an engine composed with isolated
  /// dependencies reads a coherent pair.
  ///
  /// The counts are point-in-time per source and not mutually atomic: a
  /// batch transitioning between states can momentarily appear in, or be
  /// missing from, one count. Terminal no-output outcomes (`failed_empty`,
  /// `skipped_short`) are neither success nor failure here.
  func processingStatus() -> ActivityProcessingStatus {
    let batches = storage.allBatches()
    return ActivityProcessingStatus(
      analyzedBatchCount: batches.filter { ActivityProcessingStatus.isSuccessStatus($0.status) }
        .count,
      pendingBatchCount: batches.filter { $0.status == "pending" }.count,
      inFlightBatchCount: analysis.inFlightBatchCount,
      failedBatchCount: batches.filter { $0.status == "failed" }.count
    )
  }

  // MARK: - Capture control

  /// Requests screen capture to start. Delegates to the engine-owned
  /// recording state (RecordingState.setRecording), which the screen recorder
  /// observes through its existing subscription. Like the manual recording
  /// toggle, the preference persists and is restored on launch.
  ///
  /// Permission UX is host-owned, not part of this call: if the
  /// screen-recording permission is missing, the recorder's existing
  /// machinery turns recording back off (without persisting that
  /// correction), and posts the screen-recording permission notice for the
  /// host to surface.
  func startCapture() {
    recordingState.setRecording(true, analyticsReason: "engine")
  }

  /// Requests screen capture to stop. Delegates to the engine-owned
  /// recording state; the preference persists, matching the manual toggle's
  /// semantics.
  func stopCapture() {
    recordingState.setRecording(false, analyticsReason: "engine")
  }

  /// Whether the recording-control flag is currently enabled: a read-only
  /// mirror of the engine-owned recording state the recorder observes. This
  /// is not an instantaneous capture sensor — the recorder pauses during
  /// sleep/lock while this flag stays true.
  var isCaptureEnabled: Bool {
    recordingState.isRecording
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
