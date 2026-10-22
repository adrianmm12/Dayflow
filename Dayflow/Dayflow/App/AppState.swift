import Combine
import SwiftUI

@MainActor  // <--- Add this
protocol AppStateManaging: ObservableObject {
  // This requirement must now be fulfilled on the main actor
  var isRecording: Bool { get }
  var objectWillChange: ObservableObjectPublisher { get }
}

/// Product compatibility layer over the engine-owned recording state
/// (`Core/Recording/RecordingState.swift`). The engine — ScreenRecorder and
/// MacActivityEngine — observes and mutates RecordingState directly; this
/// type mirrors that state and forwards mutations so existing product code
/// (RecordingControl, PauseManager, AppDelegate, UI bindings, analytics)
/// keeps working unchanged. It also still owns pure product UI context
/// (current tab/timeline mode), which is unrelated to the capture engine.
@MainActor
final class AppState: ObservableObject, AppStateManaging {  // <-- Add AppStateManaging here
  static let shared = AppState()

  private var mirror: AnyCancellable?

  /// Mirror of the engine-owned recording state. One-way: subscribing to
  /// RecordingState keeps this in sync; writes go through `setRecording`
  /// (forwarded). Direct assignment from outside this type is unavailable on
  /// purpose — the engine state is the source of truth.
  @Published private(set) var isRecording: Bool

  @Published private(set) var currentTabName: String?
  @Published private(set) var currentTimelineMode: String?

  init() {
    isRecording = RecordingState.shared.isRecording
    mirror = RecordingState.shared.$isRecording
      .sink { [weak self] recording in
        self?.isRecording = recording
      }
  }

  /// Forwards to the engine-owned recording state. See RecordingState for
  /// persistence gating and suppression semantics.
  func enablePersistence() {
    RecordingState.shared.enablePersistence()
  }

  /// Forwards to the engine-owned recording state.
  func getSavedPreference() -> Bool? {
    RecordingState.shared.getSavedPreference()
  }

  /// Forwards to the engine-owned recording state.
  func setRecording(
    _ enabled: Bool,
    analyticsReason: String? = nil,
    persistPreference: Bool = true
  ) {
    RecordingState.shared.setRecording(
      enabled, analyticsReason: analyticsReason, persistPreference: persistPreference)
  }

  /// Forwards to the engine-owned recording state.
  func consumePendingRecordingAnalyticsReason() -> String? {
    RecordingState.shared.consumePendingRecordingAnalyticsReason()
  }

  func updateCurrentUIContext(tabName: String, timelineMode: String? = nil) {
    currentTabName = tabName
    currentTimelineMode = tabName == "timeline" ? timelineMode : nil
  }
}
