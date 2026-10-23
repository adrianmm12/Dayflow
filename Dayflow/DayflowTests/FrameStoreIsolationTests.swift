import CoreGraphics
import XCTest

@testable import Dayflow

/// Isolated-construction tests for `FrameStore`.
///
/// Every `FrameStore` here is built against its own `StorageManager(isolatedAt:)`
/// temporary tree. `FrameStore.shared` is never constructed or touched, no
/// ScreenCaptureKit API is ever involved, and the production recordings
/// directory is only ever *computed* for inequality assertions. Frames are
/// synthetic images drawn into a `CGContext`, never the real screen.
final class FrameStoreIsolationTests: XCTestCase {
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
      .appendingPathComponent("dayflow-isolated-framestore-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(root)
    return root
  }

  private func makeStorage() -> StorageManager {
    StorageManager(isolatedAt: makeTempRoot())
  }

  /// The real production base directory, computed the same way the production
  /// configuration does. Used only for path *inequality* assertions; nothing is
  /// ever constructed or opened against it.
  private var productionBaseDirectory: URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow", isDirectory: true)
  }

  /// A synthetic frame drawn into a `CGContext` — no screen, no capture stack.
  private func makeSyntheticImage(width: Int = 320, height: Int = 240) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    let unwrapped = try XCTUnwrap(context)
    unwrapped.setFillColor(try makeColor(red: 0.25, green: 0.5, blue: 0.75))
    unwrapped.fill(CGRect(x: 0, y: 0, width: width, height: height))
    unwrapped.setFillColor(try makeColor(red: 1, green: 1, blue: 0.25))
    unwrapped.fill(CGRect(x: 16, y: 16, width: 64, height: 64))
    return try XCTUnwrap(unwrapped.makeImage())
  }

  private func makeColor(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGColor {
    try XCTUnwrap(
      CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, 1]))
  }

  // MARK: - Construction safety

  func testConstructionOpensNoSegmentAndStartsNoWork() {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)

    // No writer exists until a frame is appended, so no file is held open and
    // nothing is being written to disk by construction alone.
    XCTAssertNil(frames.activeSegmentPath)

    // The isolated recordings directory contains only what `StorageManager`
    // construction created (the empty directory itself); no segments.
    let recordings = root.appendingPathComponent("recordings")
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
    XCTAssertTrue(contents.isEmpty)
  }

  func testIsolatedSegmentPathIsDerivedFromInjectedStorageRoot() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)
    let productionBase = productionBaseDirectory.path

    let image = try makeSyntheticImage()
    let screenshotId = try XCTUnwrap(
      frames.append(image, capturedAt: Date(), idleSecondsAtCapture: nil))
    XCTAssertGreaterThan(screenshotId, 0)

    let active = try XCTUnwrap(frames.activeSegmentPath)
    let recordingsRoot = root.appendingPathComponent("recordings").path
    XCTAssertTrue(
      active.hasPrefix(recordingsRoot),
      "segment \(active) must live under the isolated recordings root \(recordingsRoot)")
    XCTAssertTrue(active.hasSuffix(".mp4"))
    XCTAssertFalse(active.hasPrefix(productionBase))

    // The screenshot row was written to the isolated database, not production.
    let unprocessed = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(unprocessed.count, 1)
    XCTAssertEqual(unprocessed.first?.filePath, active)
    XCTAssertFalse(active.hasPrefix(productionBase))

    // Finishing produces a real, non-empty segment file under the isolated root.
    frames.finishCurrentSegment()
    XCTAssertNil(frames.activeSegmentPath)
    let attributes = try FileManager.default.attributesOfItem(atPath: active)
    let bytes = try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
    XCTAssertGreaterThan(bytes, 0)
  }

  func testAppendFinishAndDecodeSyntheticFrameRoundTrip() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)

    let image = try makeSyntheticImage()
    XCTAssertNotNil(frames.append(image, capturedAt: Date(), idleSecondsAtCapture: 42))
    frames.finishCurrentSegment()

    let screenshot = try XCTUnwrap(storage.fetchUnprocessedScreenshots(since: 0).first)
    XCTAssertNotNil(screenshot.frameIndex)

    // Decode the frame back out of the finished segment without any capture stack.
    let decoded = try XCTUnwrap(frames.image(for: screenshot))
    XCTAssertEqual(decoded.width, image.width)
    XCTAssertEqual(decoded.height, image.height)
  }

  // MARK: - Multiple-instance safety

  func testTwoIsolatedFrameStoresDoNotShareWriterStateOrPaths() throws {
    let rootA = makeTempRoot()
    let rootB = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let storageB = StorageManager(isolatedAt: rootB)
    let framesA = FrameStore(storage: storageA)
    let framesB = FrameStore(storage: storageB)

    let image = try makeSyntheticImage()
    XCTAssertNotNil(framesA.append(image, capturedAt: Date(), idleSecondsAtCapture: nil))

    // A's active segment lives under A's root, never under B's.
    let activeA = try XCTUnwrap(framesA.activeSegmentPath)
    XCTAssertTrue(activeA.hasPrefix(rootA.appendingPathComponent("recordings").path))
    XCTAssertFalse(activeA.hasPrefix(rootB.path))

    // B never opened a writer and holds no segment open.
    XCTAssertNil(framesB.activeSegmentPath)

    // B's queue is idle and its database stayed empty.
    framesB.finishCurrentSegment()
    XCTAssertTrue(storageB.fetchUnprocessedScreenshots(since: 0).isEmpty)
    XCTAssertEqual(storageA.fetchUnprocessedScreenshots(since: 0).count, 1)

    framesA.finishCurrentSegment()
  }

  // MARK: - Reconciliation

  func testReconcileAfterLaunchReconcilesOnlyInjectedStore() throws {
    let rootA = makeTempRoot()
    let rootB = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let storageB = StorageManager(isolatedAt: rootB)
    let framesA = FrameStore(storage: storageA)
    let framesB = FrameStore(storage: storageB)

    // Crash-recovery stand-ins: rows whose segment files never made it to disk.
    let ghostA = rootA.appendingPathComponent("recordings").appendingPathComponent("ghostA.mp4").path
    let ghostB = rootB.appendingPathComponent("recordings").appendingPathComponent("ghostB.mp4").path
    XCTAssertNotNil(
      storageA.saveScreenshot(segmentPath: ghostA, frameIndex: 0, capturedAt: Date(), idleSecondsAtCapture: nil))
    XCTAssertNotNil(
      storageB.saveScreenshot(segmentPath: ghostB, frameIndex: 0, capturedAt: Date(), idleSecondsAtCapture: nil))

    // Reconcile only A. `finishCurrentSegment` is synchronous on the same write
    // queue, so it also acts as a barrier proving the async reconcile completed.
    framesA.reconcileAfterLaunch()
    framesA.finishCurrentSegment()

    // A's missing segment was soft-deleted (crash-recovery semantics preserved).
    XCTAssertTrue(storageA.fetchUnprocessedScreenshots(since: 0).isEmpty)

    // B was never reconciled, so its row is untouched.
    XCTAssertEqual(storageB.fetchUnprocessedScreenshots(since: 0).count, 1)
    XCTAssertEqual(storageB.fetchUnprocessedScreenshots(since: 0).first?.filePath, ghostB)
  }
}
