//
//  AppDelegate.swift
//  Dayflow
//
//  Headless engine-host application delegate. Owns exactly the Mac engine
//  lifecycle: constructing and starting MacActivityEngine, enabling
//  RecordingState persistence, restoring the saved recording preference
//  (gated on the screen-recording TCC grant), starting the analysis job,
//  and flushing engine storage on termination.
//
//  The former product-shell wiring (Dock icon preference, status item,
//  Sparkle updates, auth session, analytics heartbeat, deep links, Flow,
//  product notifications, launch-at-login, inactivity/screenshot trackers)
//  was removed in the headless-host stripping slice. Engine compile
//  dependencies under System/ (AnalyticsService, DayflowAuthManager,
//  DayflowBackendConfiguration, ScreenRecordingPermissionNotice) are
//  retained elsewhere in this target.
//

import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  enum PendingNotificationNavigationDestination: Equatable {
    case daily(day: String?)
    case weekly
    case support
    case flow
    case timeline
  }

  // Dormant product-notification routing surface: NotificationService
  // (Core/Notifications, scheduled for a later feature-domain slice) still
  // writes this when the user taps a product notification. No host code
  // reads it anymore; retained temporarily to avoid Core/Notifications
  // surgery in this slice.
  static var pendingNotificationNavigationDestination: PendingNotificationNavigationDestination? =
    nil

  private var activityEngine: MacActivityEngine!

  override init() {
    // First-launch migration of the pre-fork sandboxed defaults domain.
    // A no-op once the sentinel key exists.
    UserDefaultsMigrator.migrateIfNeeded()
    super.init()
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    // Configure crash reporting (Sentry) from the shared telemetry
    // preference. The SDK only starts if a DSN is configured; without this
    // call, retained engine code's Sentry usage stays dormant. Local
    // builds without a DSN are unaffected either way.
    SentryHelper.setEnabled(AnalyticsService.shared.isOptedIn)

    // Engine machinery: seeds the recording flag low and constructs the
    // recorder. Must stay before the persistence enablement and preference
    // restore below — see MacActivityEngine.start().
    activityEngine = MacActivityEngine()
    activityEngine.start()

    // Enable persistence of recording changes AFTER the engine's launch
    // seed so the initial low value never overwrites the user's saved
    // preference (see RecordingState.enablePersistence()).
    RecordingState.shared.enablePersistence()

    // Restore the saved recording preference, gated on the screen-recording
    // TCC grant. A missing grant turns recording off for this run WITHOUT
    // persisting that correction, so the user's preference survives. No
    // extra SCShareableContent probe: every ScreenCaptureKit call makes
    // macOS re-check the grant (issue #381), and the recorder retries with
    // backoff if capture really can't begin.
    Task { @MainActor in
      guard ScreenRecordingPermissionNotice.isGranted else {
        RecordingState.shared.setRecording(
          false, analyticsReason: "auto", persistPreference: false)
        return
      }
      let savedPref = RecordingState.shared.getSavedPreference()
      RecordingState.shared.setRecording(savedPref ?? true, analyticsReason: "auto")
    }

    // Start the provider-routed analysis background job.
    activityEngine.startAnalysisJob()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Headless host: no soft-quit product guard. Every termination request
    // (signal relay, logout, AppleEvent quit) runs the ordinary path below.
    .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Flush engine storage (checkpoint + truncate the WAL) before quit.
    // Must run only after the engine-owned recorder has deterministically
    // finished its capture work — see MacActivityEngine.shutdown().
    activityEngine?.shutdown()
  }
}
