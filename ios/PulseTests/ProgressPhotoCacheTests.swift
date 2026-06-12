/// Unit tests for `ProgressPhotoCache`, the disk + in-memory cache for
/// downloaded progress photos.
/// Covers store/read, miss, eviction (memory + disk), overwrite-by-sha,
/// and the pending → final rename path used when uploading new images.
/// Part of the iOS app's progress-photo test suite.
import XCTest
import UIKit
@testable import Pulse

final class ProgressPhotoCacheTests: XCTestCase {

    /// Creates a `ProgressPhotoCache` backed by a fresh temp directory.
    /// Outputs: tuple of `(cache, root directory URL)`.
    /// Exceptions: throws if the directory cannot be created.
    private func tempCache() throws -> (ProgressPhotoCache, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phototest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ProgressPhotoCache(rootDirectory: dir), dir)
    }

    /// Renders a 32x32 red JPEG and returns its encoded bytes.
    /// Outputs: JPEG-encoded `Data` suitable for `store(data:sha:variant:)`.
    private func jpegData() -> Data {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }

    /// Verifies a stored image can be retrieved by SHA.
    func testStoreThenReadHits() throws {
        let (cache, _) = try tempCache()
        try cache.store(data: jpegData(), sha: "abc", variant: .full)
        XCTAssertNotNil(cache.image(forSHA: "abc", variant: .full))
    }

    /// Verifies an unknown SHA returns nil instead of throwing.
    func testMissReturnsNil() throws {
        let (cache, _) = try tempCache()
        XCTAssertNil(cache.image(forSHA: "nope", variant: .full))
    }

    /// Verifies `evict(sha:)` drops the entry from memory AND removes the
    /// on-disk file for every variant.
    func testEvictRemovesFromMemoryAndDisk() throws {
        let (cache, dir) = try tempCache()
        try cache.store(data: jpegData(), sha: "x", variant: .full)
        try cache.store(data: jpegData(), sha: "x", variant: .thumb)
        cache.evict(sha: "x")
        XCTAssertNil(cache.image(forSHA: "x", variant: .full))
        XCTAssertNil(cache.image(forSHA: "x", variant: .thumb))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x_full.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x_thumb.jpg").path))
    }

    /// Verifies storing the same SHA + variant twice is idempotent.
    func testStoreOverwrites() throws {
        let (cache, _) = try tempCache()
        try cache.store(data: jpegData(), sha: "sha-same", variant: .full)
        try cache.store(data: jpegData(), sha: "sha-same", variant: .full)
        XCTAssertNotNil(cache.image(forSHA: "sha-same", variant: .full))
    }

    /// Verifies thumb and full bytes never collide under the same SHA.
    /// Storing one variant must not satisfy a lookup for the other.
    func testThumbAndFullAreIndependent() throws {
        let (cache, _) = try tempCache()
        try cache.store(data: jpegData(), sha: "sha-x", variant: .thumb)
        XCTAssertNotNil(cache.image(forSHA: "sha-x", variant: .thumb))
        XCTAssertNil(cache.image(forSHA: "sha-x", variant: .full))
    }

    /// Verifies `storePending` writes a pending file and `renameToSHA`
    /// moves it to the full-variant SHA path, leaving no pending file behind.
    func testRenamePendingToShaMovesFile() throws {
        let (cache, dir) = try tempCache()
        let pendingURL = try cache.storePending(data: jpegData(), id: UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        try cache.renameToSHA(pendingURL: pendingURL, sha: "final-sha")
        let finalURL = dir.appendingPathComponent("final-sha_full.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertNotNil(cache.image(forSHA: "final-sha", variant: .full))
    }

    /// Renders a JPEG of the given pixel size (renderer scale 1 so points == pixels).
    /// Inputs:
    ///   - width: pixel width of the rendered image.
    ///   - height: pixel height of the rendered image.
    /// Outputs: JPEG-encoded `Data`.
    private func jpegData(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }

    /// Verifies `renameToSHA` also derives and stores a thumb variant so a
    /// freshly uploaded photo's first grid render hits the local cache
    /// instead of re-downloading its own thumbnail.
    func testRenameDerivesThumbVariant() throws {
        let (cache, dir) = try tempCache()
        let pendingURL = try cache.storePending(data: jpegData(), id: UUID())
        try cache.renameToSHA(pendingURL: pendingURL, sha: "thumbed-sha")
        XCTAssertNotNil(cache.image(forSHA: "thumbed-sha", variant: .thumb))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("thumbed-sha_thumb.jpg").path))
    }

    /// Verifies the derived thumb follows the server convention: a source
    /// larger than 1024 px is downscaled to a 1024 px long edge, preserving
    /// aspect ratio; a small source is stored without upscaling.
    func testRenameDerivedThumbMatchesServerSizing() throws {
        let (cache, dir) = try tempCache()

        // Large source: 2048x512 → thumb 1024x256.
        let largePending = try cache.storePending(data: jpegData(width: 2048, height: 512), id: UUID())
        try cache.renameToSHA(pendingURL: largePending, sha: "large-sha")
        let largeThumbData = try Data(contentsOf: dir.appendingPathComponent("large-sha_thumb.jpg"))
        let largeThumb = try XCTUnwrap(UIImage(data: largeThumbData))
        XCTAssertEqual(max(largeThumb.size.width, largeThumb.size.height) * largeThumb.scale, 1024)
        XCTAssertEqual(min(largeThumb.size.width, largeThumb.size.height) * largeThumb.scale, 256)

        // Small source (true 32x32 pixels via the scale-1 helper — the no-arg
        // helper renders at device scale and would be 96 px): stored as-is,
        // never upscaled.
        let smallPending = try cache.storePending(data: jpegData(width: 32, height: 32), id: UUID())
        try cache.renameToSHA(pendingURL: smallPending, sha: "small-sha")
        let smallThumbData = try Data(contentsOf: dir.appendingPathComponent("small-sha_thumb.jpg"))
        let smallThumb = try XCTUnwrap(UIImage(data: smallThumbData))
        XCTAssertLessThanOrEqual(max(smallThumb.size.width, smallThumb.size.height) * smallThumb.scale, 32)
    }
}
