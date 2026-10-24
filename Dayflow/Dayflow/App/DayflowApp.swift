//
//  DayflowApp.swift
//  Dayflow
//
//  Headless engine-host entry point. No SwiftUI scene, no window, no menu,
//  no status surface: LSUIElement (Info.plist) plus .accessory activation
//  policy give the process no normal desktop presence. The engine lifecycle
//  (recording, analysis, storage, deterministic shutdown) runs through the
//  headless AppDelegate.
//
//  `MainWindowController` and the notification names below are retained
//  because still-compiled feature domains (Core/Notifications,
//  Core/Recording, Core/Flow, System/AnalyticsService) reference them;
//  with no scene registered, `showMainWindow()` is a harmless no-op pending
//  those feature-domain deletion slices.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
@main
enum DayflowHeadlessMain {
  /// Keeps the signal dispatch sources alive for the process lifetime.
  private static var signalSources: [DispatchSourceSignal] = []

  static func main() {
    // Writing to stdout after its reader has gone away (process launched from
    // a terminal or wrapper that exited) raises SIGPIPE and kills the process.
    // Ignore it so the write simply fails with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)

    // Manual/service-style termination must reach the normal application
    // termination path so the deterministic engine shutdown runs:
    //
    //   SIGINT / SIGTERM
    //     → NSApplication termination
    //     → AppDelegate.applicationWillTerminate
    //     → MacActivityEngine.shutdown()
    //
    // Raw POSIX signal handlers must not call Swift/AppKit APIs, so the
    // signals are ignored here and observed via dispatch sources on the
    // main queue instead.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    installTerminationRelay(signal: SIGINT)
    installTerminationRelay(signal: SIGTERM)

    let app = NSApplication.shared
    app.delegate = AppDelegate()
    // Agent-style presence (LSUIElement in Info.plist is the authoritative
    // declaration; this is defense in depth for direct-executable launches).
    app.setActivationPolicy(.accessory)
    app.run()
  }

  private static func installTerminationRelay(signal sig: Int32) {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated {
        // applicationShouldTerminate returns .terminateNow for the headless
        // host, so this runs the ordinary termination path (engine flush,
        // clean exit). Repeated signals are no-ops afterwards.
        NSApp.terminate(nil)
      }
    }
    source.resume()
    signalSources.append(source)
  }
}

// MARK: - Notification Names

extension Notification.Name {
  // Referenced by System/AnalyticsService (telemetry preference changes).
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  // Referenced by Core/Recording/TimelineActivitySignal (engine-owned
  // activity-change signal).
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  // Referenced by System/ScreenRecordingPermissionNotice, which engine
  // capture code (ScreenRecorder) calls on permission failure.
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  // Referenced by Core/Flow/FlowSessionMirror (later feature-domain slice).
  static let navigateToFlow = Notification.Name("navigateToFlow")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}
