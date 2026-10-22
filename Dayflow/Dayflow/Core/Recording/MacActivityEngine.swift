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
}
