//
//  DayflowApp.swift
//  Dayflow
//
//  Headless engine-host entry point. The SwiftUI App scene, menu commands,
//  and window registration were removed in the headless-host slice: this
//  target is now a plain AppKit agent process. The engine lifecycle
//  (recording, analysis, storage, deterministic shutdown) runs entirely
//  through the existing AppDelegate, which remains authoritative in this
//  slice. No window, status surface, or menu is created here.
//
//  `MainWindowController` and the notification names below are kept because
//  existing product code (NotificationService, FlowSessionMirror,
//  StatusBarController) still references them; with no scene registered,
//  `showMainWindow()` is a harmless no-op pending the next stripping slice.
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
    installTerminationRelay(signal: SIGINT, reason: "sigint")
    installTerminationRelay(signal: SIGTERM, reason: "sigterm")

    let app = NSApplication.shared
    app.delegate = AppDelegate()
    // Agent-style presence (LSUIElement in Info.plist is the authoritative
    // declaration; this is defense in depth for direct-executable launches).
    app.setActivationPolicy(.accessory)
    app.run()
  }

  private static func installTerminationRelay(signal sig: Int32, reason: String) {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated {
        // Unblocks AppDelegate.applicationShouldTerminate's soft-quit guard,
        // then runs the ordinary termination path (engine flush, analytics
        // finalization, clean exit). Repeated signals are no-ops afterwards.
        AppDelegate.permitTermination(reason: reason)
        NSApp.terminate(nil)
      }
    }
    source.resume()
    signalSources.append(source)
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  static let showWhatsNew = Notification.Name("showWhatsNew")
  static let showGettingStartedTour = Notification.Name("showGettingStartedTour")
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToSupport = Notification.Name("navigateToSupport")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let hideTimelineFailureToast = Notification.Name("hideTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
  static let navigateToFlow = Notification.Name("navigateToFlow")
  static let navigateToTimeline = Notification.Name("navigateToTimeline")
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
