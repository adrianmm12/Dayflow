import CoreGraphics
import XCTest

@testable import Dayflow

/// `ScreenRecorder` → injected `FrameStore` dependency tests.
///
/// Construction uses `autoStart: false`, which never calls `start()` — the only
/// path that reaches ScreenCaptureKit — so no screenshot of the real desktop is
/// ever taken here. The recorders exist only to prove which `FrameStore`
/// receives construction-time reconciliation and stop-time finalization; the
/// frames themselves are synthetic images drawn into a `CGContext`.
@MainActor
final class ScreenRecorderFrameStoreInjectionTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-recorder-injection-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
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
      try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [0.5, 0.25, 0.75, 1])))
    unwrapped.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(unwrapped.makeImage())
  }

  /// Inserts a screenshot row whose segment file never made it to disk, so
  /// launch reconciliation has something to reconcile.
  private func insertGhostRow(in storage: StorageManager, root: URL, name: String) throws -> String {
    let ghost = root.appendingPathComponent("recordings").appendingPathComponent(name).path
    XCTAssertNotNil(
      storage.saveScreenshot(
        segmentPath: ghost, frameIndex: 0, capturedAt: Date(), idleSecondsAtCapture: nil))
    return ghost
  }

  func testConstructionReconcilesInjectedFrameStoreOnly() throws {
    let rootA = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let rootB = makeTempRoot()
    let storageB = StorageManager(isolatedAt: rootB)
    let frameStoreA = FrameStore(storage: storageA)
    let frameStoreB = FrameStore(storage: storageB)

    let ghostA = try insertGhostRow(in: storageA, root: rootA, name: "ghostA.mp4")
    let ghostB = try insertGhostRow(in: storageB, root: rootB, name: "ghostB.mp4")

    // Constructing the recorder runs launch reconciliation; with `autoStart:
    // false` nothing else happens (no capture, no timer, no ScreenCaptureKit).
    let recorder = ScreenRecorder(autoStart: false, frameStore: frameStoreA)

    // `finishCurrentSegment` is synchronous on the injected store's write queue,
    // so it doubles as a barrier proving the async reconcile completed.
    frameStoreA.finishCurrentSegment()

    // Reconciliation targeted the injected store: A's missing segment was
    // soft-deleted, while B's row (different isolated store) is untouched.
    XCTAssertTrue(storageA.fetchUnprocessedScreenshots(since: 0).isEmpty)
    let bRows = storageB.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(bRows.count, 1)
    XCTAssertEqual(bRows.first?.filePath, ghostB)
    _ = recorder
  }

  func testStopFinalizesInjectedFrameStoresOpenSegment() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frameStore = FrameStore(storage: storage)

    // Construct first so launch reconciliation runs against an empty database
    // (as in production, where no writer is ever open at that point).
    let recorder = ScreenRecorder(autoStart: false, frameStore: frameStore)

    // A real segment open on the injected store, from a synthetic frame.
    let image = try makeSyntheticImage()
    XCTAssertNotNil(frameStore.append(image, capturedAt: Date(), idleSecondsAtCapture: 7))
    let openPath = try XCTUnwrap(frameStore.activeSegmentPath)
    XCTAssertTrue(openPath.hasPrefix(root.appendingPathComponent("recordings").path))

    // Stopping the recorder finalizes *its* injected store's open segment.
    recorder.stop()

    // The finalize runs on the recorder queue and then the frame-store write
    // queue; poll the (synchronous) active-path query until it reports none.
    let deadline = Date().addingTimeInterval(10)
    while frameStore.activeSegmentPath != nil && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertNil(frameStore.activeSegmentPath)

    // The segment file was finalized on disk and its row's size was written back.
    XCTAssertTrue(FileManager.default.fileExists(atPath: openPath))
    let rows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.filePath, openPath)
    XCTAssertNotNil(rows.first?.fileSize)
  }
}
