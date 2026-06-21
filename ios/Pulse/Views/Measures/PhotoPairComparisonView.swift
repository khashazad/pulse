/// Focused side-by-side comparison for exactly two selected progress photos.
import SwiftUI

/// Shows two selected same-tag photos chronologically with each date's logged
/// weight beneath the image.
struct PhotoPairComparisonView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(AuthSession.self) private var auth
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    let older: ProgressPhotoMetadata
    let newer: ProgressPhotoMetadata
    let tagName: String

    @State private var weightOlder: WeightEntry?
    @State private var weightNewer: WeightEntry?
    @State private var expanded: ExpandedPhoto?

    private struct ExpandedPhoto: Identifiable, Equatable {
        let id: UUID
        let meta: ProgressPhotoMetadata
        let tagName: String
    }

    /// Builds a read-only two-photo comparison. Inputs are normalized into
    /// chronological order even if the caller already sorted them.
    /// - Parameters:
    ///   - older: one selected photo.
    ///   - newer: the other selected photo.
    ///   - tagName: shared tag display name.
    init(older: ProgressPhotoMetadata, newer: ProgressPhotoMetadata, tagName: String) {
        let pair = orderedPair(older, newer)
        self.older = pair.older
        self.newer = pair.newer
        self.tagName = tagName
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    comparisonColumn(meta: older, weight: weightOlder)
                    comparisonColumn(meta: newer, weight: weightNewer)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, Theme.Layout.dockClearance)
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
        .navigationTitle(tagName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadWeights() }
    }

    /// Renders one side of the selected pair with photo tile and weight caption.
    /// - Parameters:
    ///   - meta: photo metadata for this side.
    ///   - weight: fetched weight entry for this photo's date.
    /// - Returns: a comparison column.
    private func comparisonColumn(meta: ProgressPhotoMetadata, weight: WeightEntry?) -> some View {
        VStack(spacing: 8) {
            ComparisonPhotoCell(
                meta: meta,
                onTap: {
                    expanded = ExpandedPhoto(id: meta.id, meta: meta, tagName: tagName)
                }
            )
            Text(weightCaption(date: meta.date, weight: weight, unitRaw: displayUnitRaw))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Fetches each photo date's logged weight in parallel.
    /// - Returns: nothing; updates `weightOlder` and `weightNewer`.
    private func loadWeights() async {
        guard let client = auth.makeClient() else { return }
        async let left = fetchWeight(for: older.date, client: client, keep: weightOlder)
        async let right = fetchWeight(for: newer.date, client: client, keep: weightNewer)
        let (olderWeight, newerWeight) = await (left, right)
        if Task.isCancelled { return }
        weightOlder = olderWeight
        weightNewer = newerWeight
    }
}
