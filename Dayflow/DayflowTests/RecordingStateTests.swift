import XCTest

@testable import Dayflow

/// Engine-owned recording-state tests on isolated instances with throwaway
/// UserDefaults suites. The shared singleton (RecordingState.shared) is
/// never mutated here: the hosted app's real ScreenRecorder observes it, so
/// toggling it would start/stop real screen capture and persist real
/// preferences.
@MainActor
final class RecordingStateTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "recording-state-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  private func makeState() -> RecordingState {
    RecordingState(defaults: defaults)
  }

  func testInitialStateIsFalseAndNothingPersisted() {
    let state = makeState()

    XCTAssertFalse(state.isRecording)
    XCTAssertNil(state.getSavedPreference())
    XCTAssertNil(defaults.object(forKey: "isRecording"))
  }

  func testMutationBeforeEnablePersistenceDoesNotPersist() {
    let state = makeState()

    state.setRecording(true, analyticsReason: "test")

    XCTAssertTrue(state.isRecording)
    // Live state changed, but the saved preference must stay untouched.
    XCTAssertNil(state.getSavedPreference())
    XCTAssertNil(defaults.object(forKey: "isRecording"))
  }

  func testMutationAfterEnablePersistencePersists() {
    let state = makeState()
    state.enablePersistence()

    state.setRecording(true, analyticsReason: "test")

    XCTAssertEqual(state.getSavedPreference(), true)
    XCTAssertEqual(defaults.bool(forKey: "isRecording"), true)
  }

  func testPersistPreferenceFalseChangesLiveStateWithoutPersisting() {
    let state = makeState()
    state.enablePersistence()
    state.setRecording(true, analyticsReason: "test")

    // A temporary correction (e.g. the recorder's permission-loss path):
    // live state goes low, the saved desired preference stays true.
    state.setRecording(false, analyticsReason: "test", persistPreference: false)

    XCTAssertFalse(state.isRecording)
    XCTAssertEqual(state.getSavedPreference(), true)
  }

  func testDirectAssignmentPersistsOnlyWhenEnabled() {
    let state = makeState()

    // Direct assignment mirrors the launch seed: before persistence is
    // enabled, it must not touch the saved preference.
    state.isRecording = false
    XCTAssertNil(state.getSavedPreference())

    state.enablePersistence()
    state.isRecording = true
    XCTAssertEqual(state.getSavedPreference(), true)
  }

  func testSavedPreferenceReadsPreexistingPersistedValue() {
    defaults.set(true, forKey: "isRecording")

    XCTAssertEqual(makeState().getSavedPreference(), true)

    // A preexisting saved false is also honored.
    defaults.set(false, forKey: "isRecording")
    XCTAssertEqual(makeState().getSavedPreference(), false)
  }

  func testAnalyticsReasonSlotIsOneShot() {
    let state = makeState()

    state.setRecording(true, analyticsReason: "probe")
    XCTAssertEqual(state.consumePendingRecordingAnalyticsReason(), "probe")
    XCTAssertNil(state.consumePendingRecordingAnalyticsReason())

    // A mutation without a reason leaves the slot empty.
    state.setRecording(false)
    XCTAssertNil(state.consumePendingRecordingAnalyticsReason())
  }

  func testEveryAssignmentEmitsOnThePublisher() {
    let state = makeState()
    var received: [Bool] = []
    let cancellable = state.$isRecording.sink { received.append($0) }
    defer { cancellable.cancel() }

    // Duplicate assignments still emit (consumers apply their own
    // duplicate filtering, as the recorder does); the initial value is
    // delivered on subscription.
    state.isRecording = true
    state.isRecording = true
    state.setRecording(false, analyticsReason: "test")

    XCTAssertEqual(received, [false, true, true, false])
  }
}
