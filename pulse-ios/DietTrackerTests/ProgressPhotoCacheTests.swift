import XCTest
import UIKit
@testable import DietTracker

final class ProgressPhotoCacheTests: XCTestCase {

    private func tempCache() throws -> (ProgressPhotoCache, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phototest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ProgressPhotoCache(rootDirectory: dir), dir)
    }

    private func jpegData() -> Data {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return img.jpegData(compressionQuality: 0.8)!
    }

    func testStoreThenReadHits() throws {
        let (cache, _) = try tempCache()
        try cache.store(data: jpegData(), sha: "abc")
        XCTAssertNotNil(cache.image(forSHA: "abc"))
    }

    func testMissReturnsNil() throws {
        let (cache, _) = try tempCache()
        XCTAssertNil(cache.image(forSHA: "nope"))
    }

    func testEvictRemovesFromMemoryAndDisk() throws {
        let (cache, dir) = try tempCache()
        try cache.store(data: jpegData(), sha: "x")
        cache.evict(sha: "x")
        XCTAssertNil(cache.image(forSHA: "x"))
        let file = dir.appendingPathComponent("x.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStoreOverwrites() throws {
        let (cache, _) = try tempCache()
        try cache.store(data: jpegData(), sha: "sha-same")
        try cache.store(data: jpegData(), sha: "sha-same")
        XCTAssertNotNil(cache.image(forSHA: "sha-same"))
    }

    func testRenamePendingToShaMovesFile() throws {
        let (cache, dir) = try tempCache()
        let pendingURL = try cache.storePending(data: jpegData(), id: UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path))
        try cache.renameToSHA(pendingURL: pendingURL, sha: "final-sha")
        let finalURL = dir.appendingPathComponent("final-sha.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertNotNil(cache.image(forSHA: "final-sha"))
    }
}
