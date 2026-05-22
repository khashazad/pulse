/// ProgressPhotoStore: coordinator for progress-photo state, cache, and uploads.
/// Holds a day -> [metadata] map (multiple photos per day, each tagged),
/// drives a worker loop that drains the PhotoUploadQueue with backoff, monitors
/// network reachability to kick the worker, and proxies reads/writes through
/// ProgressPhotoCache.
/// Role: main-actor observable injected into progress-photo screens.
import Foundation
import Network
import Observation
import UIKit

/// Main-actor coordinator that owns progress-photo metadata, caching, and the background upload worker.
@Observable
@MainActor
final class ProgressPhotoStore {
    /// Per-photo UI status used by the views.
    enum PhotoStatus: Hashable {
        case synced(sha: String)
        case uploading
        case failed
    }

    /// Each key is the local start-of-day for a calendar date; the value is
    /// every photo filed under that date, in server-supplied order.
    private(set) var photos: [Date: [ProgressPhotoMetadata]] = [:]
    private(set) var pendingCount: Int = 0
    private(set) var lastError: String?

    private weak var auth: AuthSession?
    private let cache: ProgressPhotoCache
    private let queue: PhotoUploadQueue
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "ProgressPhotoStore.monitor")
    private var workerTask: Task<Void, Never>?

    init(auth: AuthSession) {
        self.auth = auth
        self.cache = ProgressPhotoCache()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.queue = PhotoUploadQueue(fileURL: docs.appendingPathComponent("pending_uploads.json"))
        self.monitor = NWPathMonitor()
        startMonitor()
        recountPending()
    }

    deinit {
        monitor.cancel()
    }

    /// Starts the NWPathMonitor; on a satisfied path, kicks the worker on the main actor.
    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kickWorker() }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: read

    /// Returns the thumbnail UIImage for a photo, fetching and caching on demand.
    func thumb(_ meta: ProgressPhotoMetadata) async -> UIImage? {
        await image(meta: meta, size: .thumb)
    }

    /// Returns the full-size UIImage for a photo, fetching and caching on demand.
    func full(_ meta: ProgressPhotoMetadata) async -> UIImage? {
        await image(meta: meta, size: .full)
    }

    /// Photos filed under a date, in server-supplied order. Empty when none.
    func photos(on date: Date) -> [ProgressPhotoMetadata] {
        photos[normalize(date)] ?? []
    }

    private func image(meta: ProgressPhotoMetadata, size: ProgressPhotoClient.Size) async -> UIImage? {
        let variant = cacheVariant(for: size)
        if let cached = cache.image(forSHA: meta.sha256, variant: variant) { return cached }
        guard let client = auth?.makeProgressPhotoClient() else { return nil }
        do {
            let data = try await client.download(photoId: meta.id, size: size)
            try cache.store(data: data, sha: meta.sha256, variant: variant)
            return cache.image(forSHA: meta.sha256, variant: variant)
        } catch {
            return nil
        }
    }

    private func cacheVariant(for size: ProgressPhotoClient.Size) -> ProgressPhotoCache.Variant {
        switch size {
        case .full: return .full
        case .thumb: return .thumb
        }
    }

    // MARK: write

    /// Persists the image to disk, enqueues a single tagged upload, and restarts the worker so newly due work is not hidden behind an older sleep.
    ///
    /// - Parameters:
    ///   - date: Date for the progress photo.
    ///   - tagId: UUID for the photo tag assigned by the server.
    ///   - imageData: Data containing the JPEG bytes to upload.
    /// - Returns: Void.
    func upload(date: Date, tagId: UUID, imageData: Data) async {
        let id = UUID()
        do {
            let url = try cache.storePending(data: imageData, id: id)
            let pending = PendingUpload(
                id: id, date: normalize(date), tagId: tagId,
                localPath: url.path, attemptCount: 0, nextAttemptAt: Date()
            )
            try queue.enqueueSingle(pending)
            recountPending()
            workerTask?.cancel()
            workerTask = nil
            kickWorker()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Evicts the cached bytes, drops the photo from local metadata, and asks the server to delete it.
    func delete(_ meta: ProgressPhotoMetadata) async {
        let day = normalize(meta.date)
        cache.evict(sha: meta.sha256)
        photos[day]?.removeAll { $0.id == meta.id }
        if photos[day]?.isEmpty == true { photos[day] = nil }
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do { try await client.delete(photoId: meta.id) }
        catch { lastError = error.localizedDescription }
    }

    // MARK: sync

    /// Refreshes server metadata across the given range, evicts now-stale sha caches,
    /// replaces the local metadata map, and kicks the worker.
    func reconcile(from: Date, to: Date) async {
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do {
            let rows = try await client.listMetadata(from: from, to: to)
            var grouped: [Date: [ProgressPhotoMetadata]] = [:]
            for row in rows {
                grouped[normalize(row.date), default: []].append(row)
            }
            let oldSHAs = Set(photos.values.flatMap { $0 }.map(\.sha256))
            let newSHAs = Set(grouped.values.flatMap { $0 }.map(\.sha256))
            for sha in oldSHAs.subtracting(newSHAs) {
                cache.evict(sha: sha)
            }
            photos = grouped
        } catch {
            lastError = error.localizedDescription
        }
        kickWorker()
    }

    /// Spawns the worker task when no active worker is running.
    ///
    /// - Returns: Void.
    func kickWorker() {
        if let existing = workerTask, !existing.isCancelled { return }
        workerTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    private func drainLoop() async {
        defer { workerTask = nil }
        while !Task.isCancelled {
            let now = Date()
            let due = queue.allDue(now: now)
            if due.isEmpty {
                guard let next = queue.nextDueDate(after: now) else { return }
                let delay = max(0, next.timeIntervalSince(now))
                let nanos = UInt64(min(delay, TimeInterval(UInt64.max / 1_000_000_000)) * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                continue
            }
            for item in due {
                await processOne(item)
            }
            recountPending()
        }
    }

    /// Attempts one queued upload and updates queue state for success, retry, or unavailable authentication.
    ///
    /// - Parameters:
    ///   - item: QueuedUpload item selected by the worker as due.
    /// - Returns: Void.
    private func processOne(_ item: QueuedUpload) async {
        guard let client = auth?.makeProgressPhotoClient() else {
            try? queue.markFailure(id: item.id)
            return
        }
        switch item {
        case .single(let p):
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: p.localPath))
            } catch {
                // Pending bytes are gone (e.g. cache cleared). Drop the entry —
                // retrying would just loop forever on the same missing file.
                lastError = error.localizedDescription
                try? queue.markSuccess(id: p.id)
                return
            }
            let meta: ProgressPhotoMetadata
            do {
                meta = try await client.upload(
                    date: p.date,
                    tagId: p.tagId,
                    jpeg: data,
                    idempotencyKey: p.id
                )
            } catch {
                // True upload failure — schedule a backoff retry.
                lastError = error.localizedDescription
                try? queue.markFailure(id: item.id)
                return
            }
            // Upload succeeded. Local bookkeeping is best-effort: a failure here
            // would previously cause a duplicate POST, but `PendingUpload.id` is
            // passed as the server idempotency key so re-uploads are deduped.
            try? cache.renameToSHA(pendingURL: URL(fileURLWithPath: p.localPath), sha: meta.sha256)
            photos[normalize(p.date), default: []].append(meta)
            try? queue.markSuccess(id: p.id)
        }
    }

    /// Recomputes the public `pendingCount` from the queue.
    private func recountPending() {
        pendingCount = queue.allDue(now: .distantFuture).count
    }

    private func normalize(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }
}
