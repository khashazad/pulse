/// Side-by-side comparison of two progress-photo dates, with a tag switcher.
/// The two dates are fixed by the gallery selection; a chip bar at the top swaps
/// which tag is compared across those same dates (only tags that have a photo on
/// both dates are offered). Each photo shows its date's logged weight.
import SwiftUI

/// Two-date comparison with a top tag switcher; photos shown side by side (older
/// left, newer right), vertically centered and filling the page width.
struct PhotoPairComparisonView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(AuthSession.self) private var auth
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    private let older: ProgressPhotoMetadata
    private let newer: ProgressPhotoMetadata
    private let initialTag: ProgressPhotoTag

    @State private var model: PhotoComparisonModel?
    @State private var expanded: ExpandedPhoto?

    private struct ExpandedPhoto: Identifiable, Equatable {
        let id: UUID
        let meta: ProgressPhotoMetadata
        let tagName: String
    }

    /// Builds the stacked comparison. The two photos are normalized to
    /// chronological order; their dates become the fixed comparison axis.
    /// - Parameters:
    ///   - older: one selected photo.
    ///   - newer: the other selected photo.
    ///   - initialTag: the tag selected when the pair was chosen.
    init(older: ProgressPhotoMetadata, newer: ProgressPhotoMetadata, initialTag: ProgressPhotoTag) {
        let pair = orderedPair(older, newer)
        self.older = pair.older
        self.newer = pair.newer
        self.initialTag = initialTag
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 14) {
                if let model, model.validTags.count > 1 {
                    TagChipBar(tags: model.validTags, selectedId: model.selectedTag.id) { model.select($0) }
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 8) {
                    photoBlock(date: model?.olderDate ?? older.date,
                               photo: model?.olderPhoto,
                               weight: model?.olderWeight)
                    photoBlock(date: model?.newerDate ?? newer.date,
                               photo: model?.newerPhoto,
                               weight: model?.newerWeight)
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
        }
        .fullScreenCover(item: $expanded) { exp in
            ProgressPhotoDetailView(
                meta: exp.meta,
                tagName: exp.tagName,
                allowsDelete: false,
                onClose: { expanded = nil }
            )
        }
        .navigationTitle(model?.selectedTag.name ?? initialTag.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if tagStore.tags.isEmpty { await tagStore.reload() }
            if model == nil {
                let m = PhotoComparisonModel(
                    initialTag: initialTag,
                    olderDate: older.date,
                    newerDate: newer.date,
                    allTags: tagStore.tags,
                    auth: auth
                )
                model = m
                await m.load()
            }
        }
    }

    /// One comparison column: the tag's photo for `date` (or a placeholder
    /// while loading / absent) with the date + weight caption beneath.
    /// - Parameters:
    ///   - date: the fixed comparison date for this row.
    ///   - photo: the selected tag's photo on that date, if resolved.
    ///   - weight: that date's logged weight, if any.
    /// - Returns: the composed row.
    @ViewBuilder
    private func photoBlock(date: Date, photo: ProgressPhotoMetadata?, weight: WeightEntry?) -> some View {
        VStack(spacing: 8) {
            if let photo {
                ComparisonPhotoCell(meta: photo) {
                    expanded = ExpandedPhoto(
                        id: photo.id, meta: photo,
                        tagName: model?.selectedTag.name ?? initialTag.name
                    )
                }
            } else {
                ComparisonPlaceholder()
            }
            Text(weightCaption(date: date, weight: weight, unitRaw: displayUnitRaw))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}
