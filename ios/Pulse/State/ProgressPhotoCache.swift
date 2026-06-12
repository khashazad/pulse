/// ProgressPhotoCache: two-level cache for progress-photo bytes.
/// Keyed by `PhotoSize` (full vs. thumb), with an NSCache-backed memory tier and
/// a disk tier under the app's caches directory; supports promoting pending
/// upload files to the cache after a successful upload.
/// Role: storage used by ProgressPhotoStore for reads, writes, and eviction.
import Foundation
import UIKit

/// On-disk + in-memory cache for progress-photo JPEG bytes.
/// Keys combine the photo's `sha256` with a `PhotoSize` (full/thumb) so that
/// thumbnail bytes never satisfy a full-size request and vice versa.
final class ProgressPhotoCache {
    /// Pixel length of a derived thumbnail's long edge. Mirrors the server's
    /// thumb rendition (1024 px long-edge JPEG) so a locally-derived thumb is
    /// interchangeable with a downloaded one.
    static let thumbLongEdgePixels: CGFloat = 1024

    private let root: URL
    private let memory = NSCache<NSString, UIImage>()

    /// Initializes the cache, creating the on-disk directory if needed.
    /// Inputs:
    ///   - rootDirectory: override location for tests; defaults to `Caches/ProgressPhotos`.
    init(rootDirectory: URL? = nil) {
        if let r = rootDirectory {
            self.root = r
        } else {
            self.root = URL.cachesDirectory.appendingPathComponent("ProgressPhotos", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        memory.totalCostLimit = 50 * 1024 * 1024
    }

    /// Returns the cached image for the given sha + variant from memory or disk; loads disk into memory on hit.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: cached UIImage, or nil if neither tier has it.
    func image(forSHA sha: String, variant: PhotoSize) -> UIImage? {
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
    func store(data: Data, sha: String, variant: PhotoSize) throws {
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
        for variant in PhotoSize.allCases {
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
    /// for the given sha, and derives the thumb variant locally so a freshly
    /// uploaded photo's first cell render doesn't re-download its own
    /// thumbnail. Called after a successful upload.
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
            storeDerivedThumb(from: img, fullData: data, sha: sha)
        }
    }

    /// Derives and stores the thumb variant from a freshly-promoted full image.
    /// Downscales to the server's thumbnail convention (1024 px long edge,
    /// JPEG); when the source already fits within that bound the full bytes
    /// are reused unchanged (the server never upscales). Best-effort: any
    /// failure leaves only the full variant cached.
    /// Inputs:
    ///   - image: decoded full-size image promoted by `renameToSHA`.
    ///   - fullData: encoded bytes of `image`, reused when no downscale is needed.
    ///   - sha: server-side content hash assigned by the upload response.
    /// Outputs: none.
    private func storeDerivedThumb(from image: UIImage, fullData: Data, sha: String) {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > Self.thumbLongEdgePixels else {
            try? store(data: fullData, sha: sha, variant: .thumb)
            return
        }
        let ratio = Self.thumbLongEdgePixels / longEdge
        let target = CGSize(
            width: (pixelSize.width * ratio).rounded(),
            height: (pixelSize.height * ratio).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumb = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = thumb.jpegData(compressionQuality: 0.85) else { return }
        try? store(data: data, sha: sha, variant: .thumb)
    }

    /// On-disk path for a given sha + variant.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: URL under the cache root.
    private func fileURL(sha: String, variant: PhotoSize) -> URL {
        root.appendingPathComponent("\(sha)_\(variant.rawValue).jpg")
    }

    /// In-memory NSCache key for a given sha + variant.
    /// Inputs:
    ///   - sha: server-side content hash identifying the photo.
    ///   - variant: full or thumb size.
    /// Outputs: composite key string used with NSCache.
    private func cacheKey(sha: String, variant: PhotoSize) -> String {
        "\(sha)_\(variant.rawValue)"
    }
}
