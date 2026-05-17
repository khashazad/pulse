import Foundation
import UIKit

/// On-disk + in-memory cache for progress-photo JPEG bytes.
/// Keys combine the photo's `sha256` with a `Variant` (full/thumb) so that
/// thumbnail bytes never satisfy a full-size request and vice versa.
final class ProgressPhotoCache {
    enum Variant: String, CaseIterable {
        case full
        case thumb
    }

    private let root: URL
    private let memory = NSCache<NSString, UIImage>()

    init(rootDirectory: URL? = nil) {
        if let r = rootDirectory {
            self.root = r
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.root = caches.appendingPathComponent("ProgressPhotos", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        memory.totalCostLimit = 50 * 1024 * 1024
    }

    func image(forSHA sha: String, variant: Variant) -> UIImage? {
        let key = cacheKey(sha: sha, variant: variant)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let url = fileURL(sha: sha, variant: variant)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString, cost: data.count)
        return img
    }

    func store(data: Data, sha: String, variant: Variant) throws {
        let url = fileURL(sha: sha, variant: variant)
        try data.write(to: url, options: .atomic)
        if let img = UIImage(data: data) {
            memory.setObject(img, forKey: cacheKey(sha: sha, variant: variant) as NSString, cost: data.count)
        }
    }

    /// Removes every variant for `sha` from memory and disk.
    func evict(sha: String) {
        for variant in Variant.allCases {
            memory.removeObject(forKey: cacheKey(sha: sha, variant: variant) as NSString)
            try? FileManager.default.removeItem(at: fileURL(sha: sha, variant: variant))
        }
    }

    func storePending(data: Data, id: UUID) throws -> URL {
        let url = root.appendingPathComponent("pending-\(id.uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Promotes a pending upload file into the cache as the full-size variant
    /// for the given sha. Called after a successful upload.
    func renameToSHA(pendingURL: URL, sha: String) throws {
        let finalURL = fileURL(sha: sha, variant: .full)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: pendingURL, to: finalURL)
        if let data = try? Data(contentsOf: finalURL), let img = UIImage(data: data) {
            memory.setObject(img, forKey: cacheKey(sha: sha, variant: .full) as NSString, cost: data.count)
        }
    }

    private func fileURL(sha: String, variant: Variant) -> URL {
        root.appendingPathComponent("\(sha)_\(variant.rawValue).jpg")
    }

    private func cacheKey(sha: String, variant: Variant) -> String {
        "\(sha)_\(variant.rawValue)"
    }
}
