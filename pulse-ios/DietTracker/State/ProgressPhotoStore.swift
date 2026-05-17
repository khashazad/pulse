/// ProgressPhotoStore: coordinator for progress-photo state, cache, and uploads.
/// Holds a day -> slot -> metadata map, drives a worker loop that drains the
/// PhotoUploadQueue with backoff, monitors network reachability to kick the
/// worker, and proxies reads/writes through ProgressPhotoCache.
/// Role: main-actor observable injected into progress-photo screens.
import Foundation
import Network
import Observation
import UIKit

/// Main-actor coordinator that owns progress-photo metadata, caching, and the background upload worker.
@Observable
@MainActor
final class ProgressPhotoStore {
    /// Per-slot UI status for a given date.
    enum SlotStatus: Hashable {
        case empty
        case synced(sha: String)
        case uploading
        case failed
    }

    private(set) var metadata: [Date: [ProgressPhotoSlot: ProgressPhotoMetadata]] = [:]
    private(set) var pendingCount: Int = 0
    private(set) var lastError: String?

    private weak var auth: AuthSession?
    private let cache: ProgressPhotoCache
    private let queue: PhotoUploadQueue
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "ProgressPhotoStore.monitor")
    private var workerTask: Task<Void, Never>?

    /// Initializes the store with a fresh cache, queue, and network monitor.
    /// Inputs:
    ///   - auth: auth session used to construct authenticated photo clients.
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

    /// Returns the thumbnail UIImage for a slot on a date, fetching and caching on demand.
    /// Inputs:
    ///   - date: calendar day.
    ///   - slot: which of the four slots.
    /// Outputs: thumbnail image, or nil when missing or fetch fails.
    func thumb(date: Date, slot: ProgressPhotoSlot) async -> UIImage? {
        await image(date: date, slot: slot, size: .thumb)
    }

    /// Returns the full-size UIImage for a slot on a date, fetching and caching on demand.
    /// Inputs:
    ///   - date: calendar day.
    ///   - slot: which of the four slots.
    /// Outputs: full-size image, or nil when missing or fetch fails.
    func full(date: Date, slot: ProgressPhotoSlot) async -> UIImage? {
        await image(date: date, slot: slot, size: .full)
    }

    /// Computes the synchronous UI status for a slot from cached metadata.
    /// Inputs:
    ///   - date: calendar day.
    ///   - slot: which of the four slots.
    /// Outputs: .synced when metadata is present, otherwise .empty.
    func status(date: Date, slot: ProgressPhotoSlot) -> SlotStatus {
        let day = normalize(date)
        if let meta = metadata[day]?[slot] {
            return .synced(sha: meta.sha256)
        }
        return .empty
    }

    /// Shared image fetch helper: returns from cache, else downloads, stores, and returns.
    /// Inputs:
    ///   - date: calendar day.
    ///   - slot: which of the four slots.
    ///   - size: full or thumb variant.
    /// Outputs: UIImage when available, or nil when metadata is missing or fetch fails.
    private func image(date: Date, slot: ProgressPhotoSlot, size: ProgressPhotoClient.Size) async -> UIImage? {
        let day = normalize(date)
        guard let meta = metadata[day]?[slot] else { return nil }
        let variant = cacheVariant(for: size)
        if let cached = cache.image(forSHA: meta.sha256, variant: variant) { return cached }
        guard let client = auth?.makeProgressPhotoClient() else { return nil }
        do {
            let data = try await client.download(date: date, slot: slot, size: size)
            try cache.store(data: data, sha: meta.sha256, variant: variant)
            return cache.image(forSHA: meta.sha256, variant: variant)
        } catch {
            return nil
        }
    }

    /// Maps the client-facing size enum to the cache's variant enum.
    /// Inputs:
    ///   - size: client size (.full / .thumb).
    /// Outputs: corresponding cache variant.
    private func cacheVariant(for size: ProgressPhotoClient.Size) -> ProgressPhotoCache.Variant {
        switch size {
        case .full: return .full
        case .thumb: return .thumb
        }
    }

    // MARK: write

    /// Persists the image to disk, enqueues a single upload, and kicks the worker.
    /// Inputs:
    ///   - date: calendar day for the photo.
    ///   - slot: target slot.
    ///   - imageData: JPEG bytes to upload.
    func upload(date: Date, slot: ProgressPhotoSlot, imageData: Data) async {
        let id = UUID()
        do {
            let url = try cache.storePending(data: imageData, id: id)
            let pending = PendingUpload(
                id: id, date: normalize(date), slot: slot,
                localPath: url.path, attemptCount: 0, nextAttemptAt: Date()
            )
            try queue.enqueueSingle(pending)
            recountPending()
            kickWorker()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Persists each image to disk, enqueues a batch upload, and kicks the worker.
    /// Inputs:
    ///   - date: calendar day for all photos in the batch.
    ///   - assignments: slot -> JPEG bytes for each photo.
    func uploadBatch(date: Date, assignments: [ProgressPhotoSlot: Data]) async {
        let batchID = UUID()
        do {
            var items: [PendingBatchUpload.Item] = []
            for (slot, data) in assignments {
                let url = try cache.storePending(data: data, id: UUID())
                items.append(.init(slot: slot, localPath: url.path))
            }
            let batch = PendingBatchUpload(
                id: batchID, date: normalize(date), items: items,
                attemptCount: 0, nextAttemptAt: Date()
            )
            try queue.enqueueBatch(batch)
            recountPending()
            kickWorker()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Evicts the cached bytes, clears local metadata, and asks the server to delete the photo.
    /// Inputs:
    ///   - date: calendar day.
    ///   - slot: target slot.
    func delete(date: Date, slot: ProgressPhotoSlot) async {
        let day = normalize(date)
        if let sha = metadata[day]?[slot]?.sha256 {
            cache.evict(sha: sha)
        }
        metadata[day]?[slot] = nil
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do { try await client.delete(date: date, slot: slot) }
        catch { lastError = error.localizedDescription }
    }

    // MARK: sync

    /// Refreshes server metadata across the given range, evicts now-stale sha caches,
    /// replaces the local metadata map, and kicks the worker.
    /// Inputs:
    ///   - from: window start (inclusive).
    ///   - to: window end (inclusive).
    func reconcile(from: Date, to: Date) async {
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do {
            let rows = try await client.listMetadata(from: from, to: to)
            var grouped: [Date: [ProgressPhotoSlot: ProgressPhotoMetadata]] = [:]
            for row in rows {
                let day = normalize(row.date)
                grouped[day, default: [:]][row.slot] = row
            }
            for (day, slots) in grouped {
                for (slot, meta) in slots {
                    if let old = metadata[day]?[slot]?.sha256, old != meta.sha256 {
                        cache.evict(sha: old)
                    }
                }
            }
            metadata = grouped
        } catch {
            lastError = error.localizedDescription
        }
        kickWorker()
    }

    /// Spawns the worker task if one isn't already running.
    func kickWorker() {
        if let existing = workerTask, !existing.isCancelled { return }
        workerTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    /// Continuously drains due queue entries; when none are due, sleeps until the next attempt time.
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

    /// Processes a single queued upload (single or batch), promoting cached bytes and updating metadata.
    /// Inputs:
    ///   - item: queued upload to process.
    private func processOne(_ item: QueuedUpload) async {
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do {
            switch item {
            case .single(let p):
                let data = try Data(contentsOf: URL(fileURLWithPath: p.localPath))
                let meta = try await client.upload(date: p.date, slot: p.slot, jpeg: data)
                try cache.renameToSHA(pendingURL: URL(fileURLWithPath: p.localPath), sha: meta.sha256)
                metadata[normalize(p.date), default: [:]][p.slot] = meta
                try queue.markSuccess(id: p.id)
            case .batch(let b):
                var assignments: [ProgressPhotoSlot: Data] = [:]
                for it in b.items {
                    assignments[it.slot] = try Data(contentsOf: URL(fileURLWithPath: it.localPath))
                }
                let results = try await client.uploadBatch(date: b.date, assignments: assignments)
                for it in b.items {
                    if let meta = results.first(where: { $0.slot == it.slot }) {
                        try cache.renameToSHA(pendingURL: URL(fileURLWithPath: it.localPath), sha: meta.sha256)
                        metadata[normalize(b.date), default: [:]][it.slot] = meta
                    }
                }
                try queue.markSuccess(id: b.id)
            }
        } catch {
            lastError = error.localizedDescription
            try? queue.markFailure(id: item.id)
        }
    }

    /// Recomputes the public `pendingCount` from the queue.
    private func recountPending() {
        pendingCount = queue.allDue(now: .distantFuture).count
    }

    /// Normalizes a date to local start-of-day for use as a metadata-map key.
    /// Inputs:
    ///   - d: date to normalize.
    /// Outputs: start of the local calendar day containing `d`.
    private func normalize(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }
}
