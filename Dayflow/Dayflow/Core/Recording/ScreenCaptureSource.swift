//
//  ScreenCaptureSource.swift
//  Dayflow
//
//  The OS screen-acquisition boundary used by `ScreenRecorder`. Every
//  ScreenCaptureKit/TCC-shaped thing the recorder does flows through here:
//  permission preflight, display enumeration, and per-tick image capture.
//  Production uses `ScreenKitCaptureSource`; tests inject a fake that answers
//  with synthetic images without touching ScreenCaptureKit or the machine's
//  screen-recording permission.
//

import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Display Snapshot

/// The display facts `ScreenRecorder` consumes — exactly the `SCDisplay`
/// fields it used to read. A value type so display-selection orchestration
/// stays independent of ScreenCaptureKit.
struct CaptureDisplay: Equatable, Sendable {
  let displayID: CGDirectDisplayID
  let width: Int
  let height: Int
}

// MARK: - Seam

/// Screen acquisition seam for `ScreenRecorder`.
///
/// Production uses `ScreenKitCaptureSource` (real ScreenCaptureKit). Tests
/// inject a fake so an isolated recorder can run its full start/capture path
/// deterministically: no `SCScreenshotManager`, no `SCShareableContent`, no
/// screen-recording permission check, no reading of the user's screen.
protocol ScreenCaptureSource: Sendable {
  /// Today: `CGPreflightScreenCaptureAccess()` via
  /// `ScreenRecordingPermissionNotice.isGranted` — a pure status read, never
  /// prompts.
  var isPermissionGranted: Bool { get }

  /// Today: `SCShareableContent.excludingDesktopWindows(false,
  /// onScreenWindowsOnly: true)`. Also refreshes the source's cached content
  /// snapshot used by `captureImage(of:width:height:)`.
  func shareableDisplays() async throws -> [CaptureDisplay]

  /// Today: `SCScreenshotManager.captureImage` with a content filter for the
  /// display (privacy-blocked running applications excluded) and a stream
  /// configuration scaled to `width` x `height`.
  func captureImage(of display: CaptureDisplay, width: Int, height: Int) async throws -> CGImage

  /// Drops cached OS content. Today: called on stop and permission loss so no
  /// `SCShareableContent` is retained while idle.
  func reset()
}

enum ScreenCaptureSourceError: Error {
  /// `captureImage` was asked for a display that is not in the cached content
  /// snapshot. Unreachable via `ScreenRecorder`, which only passes displays
  /// the same source reported.
  case noCachedDisplay
}

// MARK: - Production Source

/// Production capture source: exactly the ScreenCaptureKit calls
/// `ScreenRecorder` used to perform inline, unchanged in order and
/// configuration.
final class ScreenKitCaptureSource: ScreenCaptureSource, @unchecked Sendable {

  private let lock = NSLock()
  private var _cachedContent: SCShareableContent?

  var isPermissionGranted: Bool {
    ScreenRecordingPermissionNotice.isGranted
  }

  func shareableDisplays() async throws -> [CaptureDisplay] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    lock.withLock { _cachedContent = content }
    return content.displays.map {
      CaptureDisplay(displayID: $0.displayID, width: $0.width, height: $0.height)
    }
  }

  func captureImage(of display: CaptureDisplay, width: Int, height: Int) async throws -> CGImage {
    let content = lock.withLock { _cachedContent }
    guard
      let content,
      let scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
    else {
      throw ScreenCaptureSourceError.noCachedDisplay
    }

    // Privacy: blocked running applications are excluded from the capture.
    let excludedApplications =
      RecordingPrivacyPreferences.blockedScreenCaptureApplications(in: content)
    let filter =
      excludedApplications.isEmpty
      ? SCContentFilter(display: scDisplay, excludingWindows: [])
      : SCContentFilter(
        display: scDisplay,
        excludingApplications: excludedApplications,
        exceptingWindows: []
      )

    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.scalesToFit = true
    config.showsCursor = true

    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }

  func reset() {
    lock.withLock { _cachedContent = nil }
  }
}
