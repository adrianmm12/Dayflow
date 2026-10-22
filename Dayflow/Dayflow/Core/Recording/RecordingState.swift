//
//  RecordingState.swift
//  Dayflow
//
//  Engine-owned recording-enabled state: the source of truth for whether
//  screen capture is on. Moved verbatim from App/AppState.swift (which is
//  now a thin product compatibility adapter mirroring this state), so the
//  capture engine — ScreenRecorder, MacActivityEngine — no longer depends
//  on a type in App/.
//
//  Semantics preserved exactly:
//  - persistence to UserDefaults "isRecording" is gated until
//    enablePersistence() is called by the host's onboarding/startup path;
//  - setRecording(persistPreference: false) mutates the live state without
//    replacing the saved preference (used by the recorder's permission-loss
//    self-correction);
//  - the analytics-reason slot records who toggled recording, for the host's
//    analytics consumers.
//

import Combine
import Foundation

@MainActor
final class RecordingState: ObservableObject {
  static let shared = RecordingState()

  private let defaults: UserDefaults
  private let recordingKey = "isRecording"
  private var shouldPersist = false
  private var skipNextPersistence = false
  private var pendingRecordingAnalyticsReason: String?

  @Published var isRecording: Bool {
    didSet {
      defer { skipNextPersistence = false }

      // Only persist once the host has enabled persistence (after the
      // launch seed), and when the mutation did not opt out.
      if shouldPersist && !skipNextPersistence {
        defaults.set(isRecording, forKey: recordingKey)
      }
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.isRecording = false
  }

  /// Enables persistence of recording changes. The host calls this after its
  /// launch seed, so the initial low value never overwrites the user's saved
  /// preference.
  func enablePersistence() {
    shouldPersist = true
  }

  /// The user's saved recording preference, if one was ever persisted.
  func getSavedPreference() -> Bool? {
    if defaults.object(forKey: recordingKey) != nil {
      return defaults.bool(forKey: recordingKey)
    }
    return nil
  }

  func setRecording(
    _ enabled: Bool,
    analyticsReason: String? = nil,
    persistPreference: Bool = true
  ) {
    if let analyticsReason {
      pendingRecordingAnalyticsReason = analyticsReason
    }
    skipNextPersistence = !persistPreference
    isRecording = enabled
  }

  /// One-shot read of the reason attached to the most recent
  /// setRecording call, for analytics consumers.
  func consumePendingRecordingAnalyticsReason() -> String? {
    let reason = pendingRecordingAnalyticsReason
    pendingRecordingAnalyticsReason = nil
    return reason
  }
}
