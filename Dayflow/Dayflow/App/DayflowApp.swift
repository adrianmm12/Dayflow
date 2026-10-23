//
//  DayflowApp.swift
//  Dayflow
//

import Sparkle
import SwiftUI

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  init() {
    // Writing to stdout after its reader has gone away (app launched from a
    // terminal or wrapper that exited) raises SIGPIPE and kills the process.
    // Ignore it so the write simply fails with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)
  }

  // Sparkle updater manager
  private let updaterManager = UpdaterManager.shared

  var body: some Scene {
    Window("Dayflow", id: "main") {
      // Minimal host shell. The presentation layer (Views/, Menu/) was removed
      // in the first stripping slice; the engine lifecycle (recording,
      // analysis, storage) runs entirely through AppDelegate. This window just
      // keeps the app a regular SwiftUI-lifecycle process with an openable main
      // window (menu bar / deep links still call MainWindowController).
      ZStack {
        MainWindowRegistrationView()
      }
      .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1195, height: 675)

    .commands {
      // Remove the "New Window" command if you want a single window app
      CommandGroup(replacing: .newItem) {}

      // Add custom menu items after the app info section
      CommandGroup(after: .appInfo) {
        Divider()
        Button("Reset Onboarding") {
          // Reset the onboarding flag
          UserDefaults.standard.set(false, forKey: "didOnboard")
          // Reset the saved onboarding step to start from beginning
          UserDefaults.standard.set(0, forKey: "onboardingStep")
          UserDefaults.standard.removeObject(forKey: "onboardingHasPaidAI")
          UserDefaults.standard.removeObject(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingCategoriesCustomized)
          UserDefaults.standard.removeObject(forKey: "onboardingSelectedProviderID")
          // Force quit and restart the app to show onboarding
          Task { @MainActor in
            AppDelegate.permitTermination(reason: "reset_onboarding")
            NSApp.terminate(nil)
          }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
      }

      // Add Sparkle's update menu item
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updaterManager.checkForUpdates(showUI: true)
        }

        Button("View Release Notes") {
          // Activate the app and bring to foreground
          NSApp.activate(ignoringOtherApps: true)

          // Post notification to show What's New modal
          NotificationCenter.default.post(name: .showWhatsNew, object: nil)
        }
        .keyboardShortcut("N", modifiers: [.command, .shift])
      }

      CommandGroup(after: .appInfo) {
        Divider()
        Button("Flow: Simulate Distraction") {
          FlowSessionMirror.shared.simulateDistraction()
        }
        .keyboardShortcut("D", modifiers: [.command, .shift])
        Button("Flow: Nudge Style — \(FlowNudgeVariant.current.title)") {
          FlowNudgeVariant.current = FlowNudgeVariant.current.next
        }
      }
    }
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

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
