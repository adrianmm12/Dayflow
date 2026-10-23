import CoreGraphics
import XCTest

@testable import Dayflow

/// `ScreenRecorder` → injected `RecordingState` dependency tests.
///
/// Safety model: a recorder is never attached to a state that is observed
/// turning *on* — `start()` is the only path to ScreenCaptureKit. Instead, each
/// injected state is seeded to `true` **before** construction (no recorder
/// attached yet), so `init` reads it into `wantsRecording` but `autoStart: false`
/// never calls `start()`, and `.dropFirst()` discards the subscription's initial
/// emission. The only transition the recorder then observes is `true → false`,
/// which drives exclusively the sink's `stop()` branch — finalization, no
/// capture. No real screen is ever captured and `RecordingState.shared` /
/// production defaults are never touched.
@MainActor
final class ScreenRecorderRecordingStateInjectionTests: XCTestCase {
  private var tempRoots: [URL] = []
  private var suites: [(defaults: UserDefaults, name: String)] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    for (defaults, name) in suites {
      defaults.removePersistentDomain(forName: name)
    }
    suites.removeAll()
    super.tearDown()
  }

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-recorder-state-injection-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeIsolatedState() -> RecordingState {
    let name = "recorder-state-injection-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.append((defaults, name))
    return RecordingState(defaults: defaults)
  }

  /// A synthetic frame drawn into a `CGContext` — no screen, no capture stack.
  private func makeSyntheticImage(width: Int = 320, height: Int = 240) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    let unwrapped = try XCTUnwrap(context)
    unwrapped.setFillColor(
      try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [0.1, 0.6, 0.3, 1])))
    unwrapped.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(unwrapped.makeImage())
  }

  /// Polls the (synchronous) active-segment query until it reports `nil` or the
  /// deadline passes, so the async sink → `stop()` → finalize chain completes.
  private func waitUntilSegmentFinalized(_ frameStore: FrameStore, timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while frameStore.activeSegmentPath != nil && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  func testConstructionUsesInjectedStateWithoutStartingCapture() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()

    // autoStart: false — construction reads the (false) injected state, never
    // touches ScreenCaptureKit, and opens no segment.
    let recorder = ScreenRecorder(autoStart: false, frameStore: frames, recordingState: state)
    _ = recorder

    XCTAssertFalse(state.isRecording)
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertTrue(storage.fetchUnprocessedScreenshots(since: 0).isEmpty)
  }

  func testInjectedStateDrivesRecorderStopAndFinalization() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)

    // Seed the injected state ON before any recorder exists to observe the
    // change. With autoStart: false the recorder never starts from this.
    let state = makeIsolatedState()
    state.setRecording(true, persistPreference: false)
    XCTAssertTrue(state.isRecording)

    let recorder = ScreenRecorder(autoStart: false, frameStore: frames, recordingState: state)

    // A real segment open on the injected frame store, from a synthetic frame.
    let image = try makeSyntheticImage()
    XCTAssertNotNil(frames.append(image, capturedAt: Date(), idleSecondsAtCapture: 5))
    let openPath = try XCTUnwrap(frames.activeSegmentPath)

    // The only transition this recorder observes: true → false → stop() branch
    // of the sink (never start(), never ScreenCaptureKit).
    state.setRecording(false, persistPreference: false)

    waitUntilSegmentFinalized(frames)
    XCTAssertNil(frames.activeSegmentPath)

    // The injected state drove the recorder's stop: its injected frame store's
    // open segment was finalized, with exactly the one synthetic frame.
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPath))
    let rows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.filePath, openPath)
    XCTAssertNotNil(rows.first?.fileSize)
    _ = recorder
  }

  func testRecorderIgnoresUnrelatedIsolatedState() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)

    let stateA = makeIsolatedState()
    stateA.setRecording(true, persistPreference: false)
    let recorder = ScreenRecorder(autoStart: false, frameStore: frames, recordingState: stateA)

    let image = try makeSyntheticImage()
    XCTAssertNotNil(frames.append(image, capturedAt: Date(), idleSecondsAtCapture: nil))
    let openPath = try XCTUnwrap(frames.activeSegmentPath)

    // A second isolated state flips on and off. Recorder A does not observe it,
    // so nothing happens to A's open segment.
    let stateB = makeIsolatedState()
    stateB.setRecording(true, persistPreference: false)
    stateB.setRecording(false, persistPreference: false)

    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(frames.activeSegmentPath, openPath, "unrelated state changes must not stop recorder A")

    // Recorder A still responds to ITS injected state afterwards.
    stateA.setRecording(false, persistPreference: false)
    waitUntilSegmentFinalized(frames)
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPath))
    XCTAssertEqual(storage.fetchUnprocessedScreenshots(since: 0).count, 1)
    _ = recorder
  }
}
