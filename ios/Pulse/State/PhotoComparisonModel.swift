/// View-model for the two-date progress-photo comparison. Holds two fixed dates
/// and lets the user switch which tag is compared across them. Loads all photo
/// metadata once to compute which tags have a photo on BOTH dates (the only
/// switchable tags) and to resolve each side's photo, plus each date's logged
/// weight. Main-actor observable injected into `PhotoPairComparisonView`.
import Foundation
import Observation

/// Main-actor observable backing the stacked two-date comparison with a tag switcher.
@Observable
@MainActor
final class PhotoComparisonModel {
    /// Older (top) comparison date — start-of-day.
    let olderDate: Date
    /// Newer (bottom) comparison date — start-of-day.
    let newerDate: Date

    /// Currently compared tag.
    private(set) var selectedTag: ProgressPhotoTag
    /// Tags that have a photo on both dates (the switchable set), in display order.
    private(set) var validTags: [ProgressPhotoTag] = []
    /// Selected tag's photo on the older date, if any.
    private(set) var olderPhoto: ProgressPhotoMetadata?
    /// Selected tag's photo on the newer date, if any.
    private(set) var newerPhoto: ProgressPhotoMetadata?
    /// Weight logged on the older date (date-fixed, independent of tag).
    private(set) var olderWeight: WeightEntry?
    /// Weight logged on the newer date (date-fixed, independent of tag).
    private(set) var newerWeight: WeightEntry?
    /// Whether the initial metadata/weight load is still in flight.
    private(set) var isLoading = true

    private let allTags: [ProgressPhotoTag]
    private weak var auth: AuthSession?
    private var metadata: [ProgressPhotoMetadata] = []

    /// Builds the comparison model for two fixed dates.
    /// - Parameters:
    ///   - initialTag: the tag selected on entry (from the gallery selection).
    ///   - olderDate: the older of the two compared dates.
    ///   - newerDate: the newer of the two compared dates.
    ///   - allTags: every known tag, in display order (filtered down to `validTags`).
    ///   - auth: session provider for the photo/weight clients (held weakly).
    /// - Returns: a model in the loading state until `load()` runs.
    init(
        initialTag: ProgressPhotoTag,
        olderDate: Date,
        newerDate: Date,
        allTags: [ProgressPhotoTag],
        auth: AuthSession
    ) {
        self.selectedTag = initialTag
        self.olderDate = olderDate
        self.newerDate = newerDate
        self.allTags = allTags
        self.auth = auth
    }

    /// Fetches all photo metadata, computes the switchable tags, resolves the
    /// selected tag's two photos, and loads each date's weight. Best-effort:
    /// network failures leave the affected fields empty rather than erroring.
    /// - Returns: Void.
    func load() async {
        isLoading = true
        if let photoClient = auth?.makeProgressPhotoClient() {
            metadata = (try? await photoClient.listMetadata(
                from: Date(timeIntervalSince1970: 0), to: Date()
            )) ?? []
        }
        validTags = tagsWithPhotosOnBothDates(
            tags: allTags, metadata: metadata, dayA: olderDate, dayB: newerDate
        )
        // Keep the entry tag selected when valid; otherwise fall back so the view
        // always shows a populated pair.
        if !validTags.contains(where: { $0.id == selectedTag.id }), let first = validTags.first {
            selectedTag = first
        }
        updatePhotos()

        if let client = auth?.makeClient() {
            async let older = fetchWeight(for: olderDate, client: client, keep: olderWeight)
            async let newer = fetchWeight(for: newerDate, client: client, keep: newerWeight)
            let (o, n) = await (older, newer)
            if !Task.isCancelled {
                olderWeight = o
                newerWeight = n
            }
        }
        isLoading = false
    }

    /// Switches the compared tag (no network call — photos are already loaded).
    /// - Parameter tag: the tag to compare; should be one of `validTags`.
    /// - Returns: Void.
    func select(_ tag: ProgressPhotoTag) {
        selectedTag = tag
        updatePhotos()
    }

    /// Recomputes `olderPhoto`/`newerPhoto` for the current tag from cached metadata.
    /// - Returns: Void.
    private func updatePhotos() {
        olderPhoto = photo(for: selectedTag, on: olderDate, in: metadata)
        newerPhoto = photo(for: selectedTag, on: newerDate, in: metadata)
    }
}
