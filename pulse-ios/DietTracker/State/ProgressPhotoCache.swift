/// ProgressPhotoCache: two-level cache for progress-photo bytes.
/// Defines `Variant` (full vs. thumb), an NSCache-backed memory tier, and a
/// disk tier under the app's caches directory; supports promoting pending
/// upload files to the cache after a successful upload.
/// Role: storage used by ProgressPhotoStore for reads, writes, and eviction.
import Foundation
import UIKit

/// On-disk + in-memory cache for progress-photo JPEG bytes.
/// Keys combine the photo's `sha256` with a `Variant` (full/thumb) so that
/// thumbnail bytes never satisfy a full-size request and vice versa.
final class ProgressPhotoCache {
    /// Image-size variants stored independently in the cache.
    enum Variant: String, CaseIterable {
        case full
        case thumb
    }

    private let root: URL
    private let memory = NSCache<NSString, UIImage>()

    /// Initializes the cache, creating the on-disk directory if needed.
    /// Inputs:
    ///   - rootDirectory: override location for tests; defaults to `Caches/ProgressPhotos`.
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

    /// Returns the cached image for the given sha + variant from memory or disk; loads disk into memory on hit.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: cached UIImage, or nil if neither tier has it.
    func image(forSHA sha: String, variant: Variant) -> UIImage? {
        let key = cacheKey(sha: sha, variant: variant)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let url = fileURL(sha: sha, variant: variant)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString, cost: data.count)
        return img
    }

    /// Writes JPEG bytes to disk and warms the in-memory cache.
    /// Inputs:
    ///   - data: JPEG bytes to persist.
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Exceptions: rethrows errors from atomic disk write.
    func store(data: Data, sha: String, variant: Variant) throws {
        let url = fileURL(sha: sha, variant: variant)
        try data.write(to: url, options: .atomic)
        if let img = UIImage(data: data) {
            memory.setObject(img, forKey: cacheKey(sha: sha, variant: variant) as NSString, cost: data.count)
        }
    }

    /// Removes every variant for `sha` from memory and disk.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo to evict.
    func evict(sha: String) {
        for variant in Variant.allCases {
            memory.removeObject(forKey: cacheKey(sha: sha, variant: variant) as NSString)
            try? FileManager.default.removeItem(at: fileURL(sha: sha, variant: variant))
        }
    }

    /// Writes JPEG bytes to a pending-upload file keyed by a transient id.
    /// Inputs:
    ///   - data: JPEG bytes to persist.
    ///   - id: transient identifier for the upload, used in the file name.
    /// Outputs: file URL of the pending bytes (later renamed to sha after upload).
    /// Exceptions: rethrows errors from atomic disk write.
    func storePending(data: Data, id: UUID) throws -> URL {
        let url = root.appendingPathComponent("pending-\(id.uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Promotes a pending upload file into the cache as the full-size variant
    /// for the given sha. Called after a successful upload.
    /// Inputs:
    ///   - pendingURL: location of the pending bytes produced by `storePending`.
    ///   - sha: server-side content hash assigned by the upload response.
    /// Exceptions: rethrows errors from move or read operations.
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

    /// On-disk path for a given sha + variant.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: URL under the cache root.
    private func fileURL(sha: String, variant: Variant) -> URL {
        root.appendingPathComponent("\(sha)_\(variant.rawValue).jpg")
    }

    /// In-memory NSCache key for a given sha + variant.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: composite key string used with NSCache.
    private func cacheKey(sha: String, variant: Variant) -> String {
        "\(sha)_\(variant.rawValue)"
    }
}
