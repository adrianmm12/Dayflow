import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermissionNotice {
  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Triggers the system Screen Recording permission prompt, returning
  /// whether access is granted. A no-op (no prompt) when access is already
  /// granted, and returns false immediately when previously denied — safe
  /// to call on every launch.
  ///
  /// The headless engine host needs this: it gates capture on `isGranted`
  /// (a pure status read that never prompts), and the TCC dialog only
  /// materializes when an actual ScreenCaptureKit call is made. Without
  /// this request, a clean machine would leave the engine silently idle —
  /// the gate prevents the very capture attempt that would surface the
  /// prompt.
  @discardableResult
  static func requestAccess() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  /// Posted when macOS reports access as granted but every capture request
  /// keeps failing, so the notice shows even though `isGranted` is true.
  static let captureFailingReason = "capture_failing_while_granted"

  static func post(reason: String) {
    let notification = {
      NotificationCenter.default.post(
        name: .showScreenRecordingPermissionNotice,
        object: nil,
        userInfo: ["reason": reason]
      )
    }

    if Thread.isMainThread {
      notification()
    } else {
      DispatchQueue.main.async(execute: notification)
    }
  }

  static func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    else { return }

    NSWorkspace.shared.open(url)
  }
}
