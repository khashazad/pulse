/// ProgressPhotoTagStore: observable cache + CRUD coordinator for the user's
/// progress-photo tag catalog. Wraps `ProgressPhotoClient` tag endpoints with
/// a main-actor `[ProgressPhotoTag]` published list plus helpers to look up a
/// tag by id (used by the photo-grid sections).
import Foundation
import Observation

/// Main-actor observable that owns the user's progress-photo tag list.
@Observable
@MainActor
final class ProgressPhotoTagStore {
    private(set) var tags: [ProgressPhotoTag] = []
    private(set) var lastError: String?

    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

    /// Drops the cached tag catalog and any recorded error so no prior-session
    /// data survives sign-out.
    /// - Returns: Void.
    func clear() {
        tags = []
        lastError = nil
    }

    /// Returns the cached tag for an id, or `nil` if not yet loaded.
    func tag(id: UUID) -> ProgressPhotoTag? {
        tags.first(where: { $0.id == id })
    }

    /// Re-fetches the catalog from the server, replacing the local list.
    func reload() async {
        guard let client = auth?.makeProgressPhotoClient() else { return }
        do {
            tags = try await client.listTags()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Creates a new tag and inserts it into the local list.
    /// Returns the new tag on success, nil on failure (`lastError` populated).
    @discardableResult
    func create(name: String) async -> ProgressPhotoTag? {
        guard let client = auth?.makeProgressPhotoClient() else { return nil }
        do {
            let tag = try await client.createTag(name: name)
            tags.append(tag)
            tags.sort { ($0.sortOrder, $0.normalizedName) < ($1.sortOrder, $1.normalizedName) }
            return tag
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Renames a tag and updates the local list in place.
    /// Returns the updated tag on success, nil on failure (`lastError` populated).
    @discardableResult
    func rename(id: UUID, name: String) async -> ProgressPhotoTag? {
        guard let client = auth?.makeProgressPhotoClient() else { return nil }
        do {
            let updated = try await client.updateTag(id: id, name: name)
            if let idx = tags.firstIndex(where: { $0.id == id }) {
                tags[idx] = updated
            }
            tags.sort { ($0.sortOrder, $0.normalizedName) < ($1.sortOrder, $1.normalizedName) }
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
