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
    //
    // When the grant is missing, request it once: CGRequestScreenCaptureAccess
    // surfaces the system prompt (the preflight never does), and a headless
    // launch would otherwise never show it — the capture gate below prevents
    // the ScreenCaptureKit call that would. Granting in the dialog lets this
    // same launch proceed to recording; denying leaves the run idle with the
    // preference intact. Already-granted and previously-denied states return
    // immediately without prompting, so this is a no-op on every later launch.
    Task { @MainActor in
      if !ScreenRecordingPermissionNotice.isGranted
        && !ScreenRecordingPermissionNotice.requestAccess()
      {
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
