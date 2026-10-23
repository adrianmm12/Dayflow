import AppKit
import XCTest

@testable import Dayflow

/// Read-side isolation for screenshot image loading: a `Screenshot` row created
/// by an isolated `FrameStore` decodes explicitly through that store —
/// `loadCGImage(from:)` / `jpegData(from:)` / `writeJPEG(from:)` — with no
/// implicit `FrameStore.shared` jump. `FrameStore.shared` is never constructed
/// or touched by the isolated paths, and the zero-argument production
/// conveniences stay compile-compatible (exercised on a legacy JPEG row, which
/// is file-backed and store-independent, exactly as the existing provider
/// tests already do).
final class ScreenshotImageLoadingIsolationTests: XCTestCase {
  private var tempRoots: [URL] = []
  private var tempFiles: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    for url in tempFiles {
      try? FileManager.default.removeItem(at: url)
    }
    tempFiles.removeAll()
    super.tearDown()
  }

  // MARK: - Fixtures

  private func makeTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "dayflow-image-loading-\(UUID().uuidString)", isDirectory: true)
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
      try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [0.2, 0.4, 0.8, 1])))
    unwrapped.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(unwrapped.makeImage())
  }

  /// Appends one synthetic frame to `frames` and returns the persisted row.
  private func appendSyntheticRow(
    to frames: FrameStore, storage: StorageManager, capturedAt: Int
  ) throws -> Screenshot {
    let before = storage.fetchUnprocessedScreenshots(since: 0).count
    let image = try makeSyntheticImage()
    let id = try XCTUnwrap(
      frames.append(image, capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAt)),
        idleSecondsAtCapture: 3))
    let rows = storage.fetchUnprocessedScreenshots(since: 0)
    XCTAssertEqual(rows.count, before + 1)
    return try XCTUnwrap(rows.first { $0.id == id })
  }

  // MARK: - Explicit-store decoding

  func testSegmentRowDecodesJPEGEncodesAndWritesThroughItsOwningFrameStore() throws {
    let rootA = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let framesA = FrameStore(storage: storageA)

    // A second, fully separate composition rooted elsewhere.
    let rootB = makeTempRoot()
    let storageB = StorageManager(isolatedAt: rootB)
    let framesB = FrameStore(storage: storageB)

    // Synthetic HEVC frame → real row in isolated storage A (segment still open).
    let rowA = try appendSyntheticRow(to: framesA, storage: storageA, capturedAt: 1_000)
    XCTAssertTrue(rowA.isSegmentFrame)
    XCTAssertNotNil(framesA.activeSegmentPath)

    // B cannot accidentally satisfy A's decode: only A knows the segment is
    // still being written and can finalize it before reading. B sees an
    // unfinalized segment file and fails — proving the decode is routed by the
    // supplied store, not by whichever store happens to exist.
    XCTAssertNil(rowA.loadCGImage(from: framesB))

    // A decodes its own row through the explicit path: it finalizes the open
    // segment, then reads the frame back at full resolution.
    let decoded = try XCTUnwrap(rowA.loadCGImage(from: framesA))
    XCTAssertEqual(decoded.width, 320)
    XCTAssertEqual(decoded.height, 240)
    XCTAssertNil(framesA.activeSegmentPath, "decoding finalizes the owning store's segment")

    // JPEG serialization through the same explicit dependency: valid JPEG,
    // scaled down to the requested max height.
    let jpeg = try XCTUnwrap(rowA.jpegData(from: framesA, maxHeight: 100, quality: 0.8))
    XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG magic bytes")
    let representation = try XCTUnwrap(NSBitmapImageRep(data: jpeg))
    XCTAssertLessThanOrEqual(representation.pixelsHigh, 100)

    // writeJPEG through the same explicit dependency.
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-image-loading-\(UUID().uuidString).jpg")
    tempFiles.append(outURL)
    try rowA.writeJPEG(from: framesA, to: outURL, maxHeight: 60, quality: 0.8)
    let written = try XCTUnwrap(FileManager.default.contents(atPath: outURL.path))
    XCTAssertEqual(Array(written.prefix(2)), [0xFF, 0xD8])
    let writtenRep = try XCTUnwrap(NSBitmapImageRep(data: written))
    XCTAssertLessThanOrEqual(writtenRep.pixelsHigh, 60)

    // B stayed untouched throughout: no rows, no segment, nothing finalized.
    XCTAssertTrue(storageB.fetchUnprocessedScreenshots(since: 0).isEmpty)
    XCTAssertNil(framesB.activeSegmentPath)
  }

  func testLegacyJPEGRowStillDecodesThroughExplicitStoreAndConvenienceAPI() throws {
    let root = makeTempRoot()
    let storage = StorageManager(isolatedAt: root)
    let frames = FrameStore(storage: storage)

    // A legacy file-backed row: frameIndex nil, standalone JPEG on disk.
    let image = try makeSyntheticImage(width: 64, height: 48)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
    let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    let fileURL = root.appendingPathComponent("legacy-\(UUID().uuidString).jpg")
    try jpeg.write(to: fileURL)
    let row = Screenshot(
      id: 1, capturedAt: 1_000, filePath: fileURL.path, fileSize: nil,
      idleSecondsAtCapture: nil, isDeleted: false)

    // The explicit path preserves the legacy JPEG fallback exactly.
    let decoded = try XCTUnwrap(row.loadCGImage(from: frames))
    XCTAssertEqual(decoded.width, 64)
    XCTAssertEqual(decoded.height, 48)
    let legacyJPEG = try XCTUnwrap(row.jpegData(from: frames, maxHeight: 48, quality: 0.8))
    XCTAssertEqual(Array(legacyJPEG.prefix(2)), [0xFF, 0xD8])

    // The zero-argument production convenience remains compile-compatible and
    // behaves as before for legacy rows (file-backed, independent of any
    // segment state).
    let convenience = try XCTUnwrap(row.loadCGImage())
    XCTAssertEqual(convenience.width, 64)
    XCTAssertEqual(convenience.height, 48)
    XCTAssertNotNil(row.jpegData(maxHeight: 48, quality: 0.8))
  }

  // MARK: - Provider-level routing

  func testOpenAICompatibleProviderSerializesScreenshotsThroughInjectedFrameStore()
    async throws
  {
    let rootA = makeTempRoot()
    let storageA = StorageManager(isolatedAt: rootA)
    let framesA = FrameStore(storage: storageA)

    let rootB = makeTempRoot()
    let storageB = StorageManager(isolatedAt: rootB)
    let framesB = FrameStore(storage: storageB)

    // Two synthetic HEVC rows, ten seconds apart, segment left open.
    let row1 = try appendSyntheticRow(to: framesA, storage: storageA, capturedAt: 1_000)
    let row2 = try appendSyntheticRow(to: framesA, storage: storageA, capturedAt: 1_010)
    let rows = [row1, row2]

    let configuration = OpenAICompatibleRuntimeConfiguration(
      configuration: .init(preset: .custom, baseURL: "https://example.com/v1", modelID: "m"),
      bearerToken: "test-token")

    // A provider wired to the WRONG store cannot read the rows: its
    // serialization source is the injected frame store, and B cannot finalize
    // or read A's open segment.
    let providerB = OpenAICompatibleProvider(
      configuration: configuration,
      completion: { _, _, _ in
        XCTFail("no readable screenshots, so no request should be made")
        return ""
      },
      frameStore: framesB)
    do {
      _ = try await providerB.transcribeScreenshots(
        rows, batchStartTime: Date(timeIntervalSince1970: 1000), batchId: 1)
      XCTFail("expected no-readable-screenshots failure through the wrong store")
    } catch {
      // Expected: "No readable screenshots to transcribe."
    }
    XCTAssertNotNil(framesA.activeSegmentPath, "B's provider attempt must not finalize A's segment")

    // The provider wired to the OWNING store serializes both frames: the
    // request carries two base64 JPEGs derived through framesA, and the real
    // transcription path returns parsed observations.
    var imageParts = 0
    let providerA = OpenAICompatibleProvider(
      configuration: configuration,
      completion: { request, operation, _ in
        XCTAssertEqual(operation, "transcribe_screenshots")
        imageParts = request.messages[1].content.filter { $0.type == "image_url" }.count
        for part in request.messages[1].content where part.type == "image_url" {
          XCTAssertTrue(part.image_url?.url.hasPrefix("data:image/jpeg;base64,") == true)
        }
        return
          #"{"segments":[{"start":"00:00:00","end":"00:00:10","description":"Synthetic frame."}]}"#
      },
      frameStore: framesA)
    let result = try await providerA.transcribeScreenshots(
      rows, batchStartTime: Date(timeIntervalSince1970: 1000), batchId: 1)

    XCTAssertEqual(imageParts, 2)
    XCTAssertEqual(result.observations.count, 1)
    XCTAssertEqual(result.observations.first?.startTs, 1_000)
    XCTAssertEqual(result.observations.first?.endTs, 1_010)
    // Decoding through the owning store finalized its segment on first read.
    XCTAssertNil(framesA.activeSegmentPath)
    // B never saw a single row.
    XCTAssertTrue(storageB.fetchUnprocessedScreenshots(since: 0).isEmpty)
  }
}
