import CoreGraphics
import XCTest

@testable import Dayflow

// MARK: - Fake Capture Source

/// Deterministic fake for the `ScreenCaptureSource` seam: no ScreenCaptureKit,
/// no screen-recording permission check against the OS, no reading of the
/// user's screen. It reports one synthetic display and supplies a synthetic
/// 320×240 CGImage, counting every call so tests can see exactly what the
/// recorder asked for.
final class FakeCaptureSource: ScreenCaptureSource, @unchecked Sendable {
  private let lock = NSLock()

  /// The single display the fake reports.
  let display: CaptureDisplay

  /// The answer for the permission preflight. Tests keep `true`; the
  /// missing-permission path is out of scope here.
  var permissionGranted = true

  private var _permissionChecks = 0
  private var _shareableDisplaysCalls = 0
  private var _captureImageCalls = 0
  private var _resetCalls = 0

  /// Defaults to the main display's ID (a pure CoreGraphics read, no TCC) so
  /// display selection matches what an `ActiveDisplayTracker` would report on
  /// a single-display machine.
  init(displayID: CGDirectDisplayID = CGMainDisplayID(), width: Int = 1920, height: Int = 1080) {
    self.display = CaptureDisplay(displayID: displayID, width: width, height: height)
  }

  var permissionChecks: Int { lock.withLock { _permissionChecks } }
  var shareableDisplaysCalls: Int { lock.withLock { _shareableDisplaysCalls } }
  var captureImageCalls: Int { lock.withLock { _captureImageCalls } }
  var resetCalls: Int { lock.withLock { _resetCalls } }

  var isPermissionGranted: Bool {
    lock.withLock {
      _permissionChecks += 1
      return permissionGranted
    }
  }

  func shareableDisplays() async throws -> [CaptureDisplay] {
    lock.withLock { _shareableDisplaysCalls += 1 }
    return [display]
  }

  func captureImage(of display: CaptureDisplay, width: Int, height: Int) async throws -> CGImage {
    lock.withLock { _captureImageCalls += 1 }
    return Self.syntheticImage()
  }

  func reset() {
    lock.withLock { _resetCalls += 1 }
  }

  /// A synthetic 320×240 frame drawn into a `CGContext` — no screen, no
  /// capture stack. Cached: every call returns the same immutable image.
  private static let syntheticImageLock = NSLock()
  private static var _syntheticImage: CGImage?

  static func syntheticImage() -> CGImage {
    syntheticImageLock.lock()
    defer { syntheticImageLock.unlock() }
    if let cached = _syntheticImage { return cached }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.1, 0.6, 0.3, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
    let image = context.makeImage()!
    _syntheticImage = image
    return image
  }
}

// MARK: - Tests

/// `ScreenRecorder` → injected `ScreenCaptureSource` seam tests.
///
/// The key proof: an isolated `RecordingState` flipping ON drives a recorder
/// through its real start path — setup, display selection, the immediate first
/// capture tick, append — with every OS acquisition (permission preflight,
/// display enumeration, image capture) answered by a fake. No real
/// ScreenCaptureKit call, no screen-recording permission question, nothing
/// read from the user's screen, and all output lands in isolated storage.
///
/// Test methods are `async` so the capture path's `MainActor` hops (tracker
/// read, frontmost-app privacy check) can proceed while the test polls.
@MainActor
final class ScreenRecorderCaptureSourceInjectionTests: XCTestCase {
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

  // MARK: - Fixtures

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "dayflow-recorder-capture-source-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeIsolatedState() -> RecordingState {
    let name = "recorder-capture-source-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    suites.append((defaults, name))
    return RecordingState(defaults: defaults)
  }

  /// Makes the capture path machine-independent for this test, restoring
  /// everything afterwards:
  /// - an empty privacy blocklist, so the frontmost-app placeholder branch
  ///   can't trigger no matter which app is frontmost;
  /// - a 60 s capture interval, so only the immediate first tick (the one
  ///   `setupCapture` fires without waiting on the timer) can run.
  private func isolateHostCaptureDefaults() {
    let defaults = UserDefaults.standard
    let originalBlocked = RecordingPrivacyPreferences.blockedApplicationsText(defaults: defaults)
    let originalInterval = defaults.object(forKey: ScreenshotConfig.intervalKey)
    RecordingPrivacyPreferences.saveBlockedApplicationsText("", defaults: defaults)
    defaults.set(60, forKey: ScreenshotConfig.intervalKey)
    addTeardownBlock {
      RecordingPrivacyPreferences.saveBlockedApplicationsText(originalBlocked, defaults: defaults)
      if let interval = originalInterval {
        defaults.set(interval, forKey: ScreenshotConfig.intervalKey)
      } else {
        defaults.removeObject(forKey: ScreenshotConfig.intervalKey)
      }
    }
  }

  // MARK: - Tests

  func testTurningInjectedStateOnCapturesThroughFakeSourceIntoIsolatedStorage() async throws {
    isolateHostCaptureDefaults()
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let state = makeIsolatedState()
    let fake = FakeCaptureSource()

    let recorder = ScreenRecorder(
      autoStart: false,
      frameStore: frames,
      recordingState: state,
      captureSource: fake
    )

    // Nothing has happened yet: no permission question, no display
    // enumeration, no capture request, no open segment.
    XCTAssertEqual(fake.permissionChecks, 0)
    XCTAssertEqual(fake.shareableDisplaysCalls, 0)
    XCTAssertEqual(fake.captureImageCalls, 0)
    XCTAssertNil(frames.activeSegmentPath)

    // The one transition this recorder observes: false → true, driving
    // start() → setupCapture → the immediate first capture tick.
    state.setRecording(true, persistPreference: false)

    let captureDeadline = Date().addingTimeInterval(10)
    var rows: [Screenshot] = []
    while Date() < captureDeadline {
      rows = storage.fetchUnprocessedScreenshots(since: 0)
      if !rows.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertFalse(rows.isEmpty, "fake capture should append a screenshot row")
    XCTAssertEqual(rows.count, 1)

    // Acquisition went through the seam only: permission preflight, display
    // enumeration, and image capture were all asked of the fake — never of
    // real ScreenCaptureKit or the machine's screen-recording permission.
    XCTAssertEqual(fake.shareableDisplaysCalls, 1)
    XCTAssertEqual(fake.captureImageCalls, 1)
    XCTAssertGreaterThanOrEqual(fake.permissionChecks, 1)

    // The synthetic frame reached the real append logic: metadata is in the
    // isolated database and the segment is under the isolated recordings root.
    let row = try XCTUnwrap(rows.first)
    let openPath = try XCTUnwrap(frames.activeSegmentPath)
    XCTAssertTrue(openPath.hasPrefix(root.path), "segment must live under the isolated root")
    XCTAssertEqual(row.filePath, openPath)
    XCTAssertNotNil(row.frameIndex)
    XCTAssertGreaterThan(row.capturedAt, 0)
    XCTAssertFalse(row.isDeleted)

    // Turning the state back off drives the recorder's stop branch and
    // finalizes the isolated frame store's segment.
    state.setRecording(false, persistPreference: false)

    let finalizeDeadline = Date().addingTimeInterval(10)
    while frames.activeSegmentPath != nil && Date() < finalizeDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(frames.activeSegmentPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPath))

    let finalRows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(finalRows.count, 1)
    XCTAssertEqual(finalRows.first?.filePath, openPath)
    XCTAssertNotNil(finalRows.first?.fileSize, "finalized segment should report its size")
    _ = recorder
  }

  func testTwoIsolatedRecorderCompositionsDoNotCross() async throws {
    isolateHostCaptureDefaults()

    // Composition A: isolated storage, frame store, recording state, fake
    // capture source, recorder — all separate from B's.
    let rootA = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let framesA = FrameStore(storage: storageA)
    let stateA = makeIsolatedState()
    let fakeA = FakeCaptureSource()
    let recorderA = ScreenRecorder(
      autoStart: false, frameStore: framesA, recordingState: stateA, captureSource: fakeA)

    let rootB = makeTempRoot()
    let storageB = StorageManager(isolatedAt: rootB)
    let framesB = FrameStore(storage: storageB)
    let stateB = makeIsolatedState()
    let fakeB = FakeCaptureSource()
    let recorderB = ScreenRecorder(
      autoStart: false, frameStore: framesB, recordingState: stateB, captureSource: fakeB)

    // Only composition A is turned on.
    stateA.setRecording(true, persistPreference: false)

    let captureDeadline = Date().addingTimeInterval(10)
    while storageA.fetchUnprocessedScreenshots(since: 0).isEmpty && Date() < captureDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(storageA.fetchUnprocessedScreenshots(since: 0).count, 1)
    XCTAssertEqual(fakeA.captureImageCalls, 1)

    // Composition B never started: its fake source was never consulted, no
    // segment was opened, and nothing landed in B's database.
    XCTAssertEqual(fakeB.permissionChecks, 0)
    XCTAssertEqual(fakeB.shareableDisplaysCalls, 0)
    XCTAssertEqual(fakeB.captureImageCalls, 0)
    XCTAssertNil(framesB.activeSegmentPath)
    XCTAssertTrue(storageB.fetchUnprocessedScreenshots(since: 0).isEmpty)

    let openPathA = try XCTUnwrap(framesA.activeSegmentPath)
    XCTAssertTrue(openPathA.hasPrefix(rootA.path), "segment must live under A's isolated root")

    // Each composition finalizes only its own frame store.
    stateA.setRecording(false, persistPreference: false)
    stateB.setRecording(false, persistPreference: false)

    let finalizeDeadline = Date().addingTimeInterval(10)
    while framesA.activeSegmentPath != nil && Date() < finalizeDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(framesA.activeSegmentPath)
    XCTAssertNil(framesB.activeSegmentPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPathA))
    XCTAssertEqual(storageA.fetchUnprocessedScreenshots(since: 0).count, 1)
    XCTAssertTrue(storageB.fetchUnprocessedScreenshots(since: 0).isEmpty)
    _ = recorderA
    _ = recorderB
  }
}
