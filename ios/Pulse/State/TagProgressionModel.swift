/// TagProgressionModel: view-model for one tag's all-time progress-photo grid.
/// Owns its own newest-first `[ProgressPhotoMetadata]` list, fetched across the
/// full history via the `/measures/photos` range endpoint and filtered to the
/// tag client-side. Reuses `ProgressPhotoStore` only for image bytes and
/// deletes, so it never disturbs the day-scoped Photos view's rolling window.
/// Role: main-actor observable injected into the tag-progression screens.
import Foundation
import Observation
import UIKit

/// Main-actor observable owning one tag's full-history photo list.
@Observable
@MainActor
final class TagProgressionModel {
    /// The tag this gallery is scoped to (supplies id and display name).
    let tag: ProgressPhotoTag
    /// Lifecycle of the all-time fetch for this tag.
    private(set) var state: LoadState<[ProgressPhotoMetadata]> = .idle

    private weak var auth: AuthSession?
    private let store: ProgressPhotoStore

    /// Far-past start date for the all-time fetch (the Unix epoch); the
    /// endpoint imposes no range cap so this returns every photo.
    private static let allTimeStart = Date(timeIntervalSince1970: 0)

    /// Builds the model for one tag.
    /// - Parameters:
    ///   - tag: the progress-photo tag to show the progression for.
    ///   - auth: session provider used to mint an authenticated client (held weakly).
    ///   - store: shared photo store reused for image bytes and deletes.
    /// - Returns: a configured model in the `.idle` state.
    init(tag: ProgressPhotoTag, auth: AuthSession, store: ProgressPhotoStore) {
        self.tag = tag
        self.auth = auth
        self.store = store
    }

    /// The loaded photos, or an empty array when not yet loaded / failed.
    var photos: [ProgressPhotoMetadata] {
        if case .loaded(let list) = state { return list }
        return []
    }

    /// Fetches all-time metadata, keeps only this tag's photos, and sorts them
    /// newest-first (by `date`, tie-broken by `updatedAt`). Surfaces failures
    /// as `.failed`.
    /// - Returns: Void.
    func load() async {
        guard let client = auth?.makeProgressPhotoClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let all = try await client.listMetadata(from: Self.allTimeStart, to: Date())
            let mine = all
                .filter { $0.tagId == tag.id }
                .sorted { a, b in
                    if a.date != b.date { return a.date > b.date }
                    return a.updatedAt > b.updatedAt
                }
            state = .loaded(mine)
        } catch let error as PulseError {
            state = .failed(error)
        } catch let urlError as URLError {
            state = .failed(.network(urlError))
        } catch {
            state = .failed(.network(URLError(.unknown)))
        }
    }

    /// Returns the thumbnail image for a photo, via the shared store's cache.
    /// - Parameter meta: the photo whose thumbnail is requested.
    /// - Returns: the thumbnail image, or nil if unavailable.
    func thumb(_ meta: ProgressPhotoMetadata) async -> UIImage? {
        await store.thumb(meta)
    }

    /// Returns the full-size image for a photo, via the shared store's cache.
    /// - Parameter meta: the photo whose full image is requested.
    /// - Returns: the full-size image, or nil if unavailable.
    func full(_ meta: ProgressPhotoMetadata) async -> UIImage? {
        await store.full(meta)
    }

    /// Drops a photo from the local list without a network call (used after the
    /// shared store has already deleted it server-side).
    /// - Parameter meta: the photo to remove from the loaded list.
    /// - Returns: Void.
    func remove(_ meta: ProgressPhotoMetadata) {
        guard case .loaded(var list) = state else { return }
        list.removeAll { $0.id == meta.id }
        state = .loaded(list)
    }

    /// Deletes a photo through the shared store, then removes it from this
    /// list so the grid and viewer update immediately.
    /// - Parameter meta: the photo to delete.
    /// - Returns: Void.
    func delete(_ meta: ProgressPhotoMetadata) async {
        await store.delete(meta)
        remove(meta)
    }
}
