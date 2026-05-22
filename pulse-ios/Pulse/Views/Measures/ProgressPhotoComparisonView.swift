/// Side-by-side comparison of progress photos across two dates.
///
/// Hosts `ProgressPhotoComparisonView`. The user picks date A and date B;
/// the view groups photos by tag and renders one row per tag with A on the
/// left and B on the right. Tags present on only one side render a dashed
/// "No photo" placeholder on the missing side. Reconciles both endpoints
/// through `ProgressPhotoStore.reconcile(from:to:)` and reuses
/// `ProgressPhotoStore.thumb(_:)` / `.full(_:)` for image loads.
import SwiftUI
import UIKit

struct ProgressPhotoComparisonView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss

    let initialDate: Date

    @State private var dateA: Date
    @State private var dateB: Date
    @State private var expanded: ExpandedPhoto?
    @State private var isLoading: Bool = false
    @State private var reloadTask: Task<Void, Never>?
    @Namespace private var compareNS

    private struct ExpandedPhoto: Identifiable, Equatable {
        let id: UUID
        let meta: ProgressPhotoMetadata
        let tagName: String
    }

    /// Builds the comparison view with sensible default dates.
    /// - Parameter initialDate: anchor date used for side B; side A defaults
    ///   to seven days earlier.
    init(initialDate: Date) {
        let cal = Calendar.current
        let b = cal.startOfDay(for: initialDate)
        let a = cal.date(byAdding: .day, value: -7, to: b) ?? b
        self.initialDate = b
        _dateA = State(initialValue: a)
        _dateB = State(initialValue: b)
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Layout.sectionSpacing) {
                    datePickers
                    rows
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let exp = expanded {
                ProgressPhotoDetailView(
                    meta: exp.meta,
                    tagName: exp.tagName,
                    namespace: compareNS,
                    onClose: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            expanded = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Theme.CTP.mauve)
            }
        }
        .task {
            isLoading = true
            await tagStore.reload()
            await reload()
            isLoading = false
        }
        .refreshable { await reload() }
        .onChange(of: dateA) { _, _ in scheduleReload() }
        .onChange(of: dateB) { _, _ in scheduleReload() }
        .onDisappear { reloadTask?.cancel() }
    }

    /// Cancels any in-flight reconcile and schedules a fresh one so rapid
    /// DatePicker scrubs cannot race responses onto a stale `store.photos`.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            await reload()
        }
    }

    // MARK: pickers

    private var datePickers: some View {
        HStack(spacing: 12) {
            pickerColumn(date: $dateA)
            pickerColumn(date: $dateB)
        }
    }

    private func pickerColumn(date: Binding<Date>) -> some View {
        DatePicker("", selection: date, displayedComponents: .date)
            .labelsHidden()
            .tint(Theme.CTP.mauve)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: rows

    /// Latest photo per tag for the given date. When multiple uploads share
    /// `(date, tagId)`, keeps the one with the largest `updatedAt`.
    /// - Parameter date: the calendar day to look up.
    /// - Returns: map from `tagId` to the most recent photo metadata.
    private func latestByTag(on date: Date) -> [UUID: ProgressPhotoMetadata] {
        var out: [UUID: ProgressPhotoMetadata] = [:]
        for m in store.photos(on: date) {
            if let existing = out[m.tagId], existing.updatedAt >= m.updatedAt { continue }
            out[m.tagId] = m
        }
        return out
    }

    /// Union of tag ids present on either side, ordered by tag `sortOrder`
    /// then by display name so the rows stay stable across reloads.
    /// - Parameters:
    ///   - a: map of tag id → photo for side A.
    ///   - b: map of tag id → photo for side B.
    /// - Returns: ordered list of tag ids to render as rows.
    private func orderedTagIds(_ a: [UUID: ProgressPhotoMetadata], _ b: [UUID: ProgressPhotoMetadata]) -> [UUID] {
        let ids = Set(a.keys).union(b.keys)
        return ids.sorted { lhs, rhs in
            let lo = tagStore.tag(id: lhs)?.sortOrder ?? .max
            let ro = tagStore.tag(id: rhs)?.sortOrder ?? .max
            if lo != ro { return lo < ro }
            let ln = tagStore.tag(id: lhs)?.name ?? ""
            let rn = tagStore.tag(id: rhs)?.name ?? ""
            return ln < rn
        }
    }

    @ViewBuilder
    private var rows: some View {
        let a = latestByTag(on: dateA)
        let b = latestByTag(on: dateB)
        let ids = orderedTagIds(a, b)
        if ids.isEmpty {
            if isLoading {
                ProgressView()
                    .tint(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                Text("No photos on either day.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            }
        } else {
            VStack(spacing: 20) {
                ForEach(ids, id: \.self) { tagId in
                    tagRow(tagId: tagId, leftMeta: a[tagId], rightMeta: b[tagId])
                }
            }
        }
    }

    private func tagRow(tagId: UUID, leftMeta: ProgressPhotoMetadata?, rightMeta: ProgressPhotoMetadata?) -> some View {
        let name = tagStore.tag(id: tagId)?.name ?? "Tag"
        return VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.FG.secondary)
            HStack(spacing: 12) {
                comparisonSlot(meta: leftMeta, tagName: name)
                comparisonSlot(meta: rightMeta, tagName: name)
            }
        }
    }

    @ViewBuilder
    private func comparisonSlot(meta: ProgressPhotoMetadata?, tagName: String) -> some View {
        if let meta {
            ComparisonPhotoCell(
                meta: meta,
                isExpanded: expanded?.id == meta.id,
                onTap: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        expanded = ExpandedPhoto(id: meta.id, meta: meta, tagName: tagName)
                    }
                }
            )
        } else {
            ComparisonPlaceholder()
        }
    }

    private func reload() async {
        isLoading = true
        let lo = min(dateA, dateB)
        let hi = max(dateA, dateB)
        await store.reconcile(from: lo, to: hi)
        if !Task.isCancelled { isLoading = false }
    }
}

/// Slimmed-down photo tile for the comparison grid. No tag badge (the row
/// header already labels the tag) and no context menu (delete belongs in the
/// main photos view, not here). Intentionally does not publish a
/// `matchedGeometryEffect` source — when dateA == dateB the same `meta.id`
/// would be registered twice in the same namespace, producing undefined
/// SwiftUI behavior. The detail view fades in/out instead.
/// - Parameters:
///   - `meta`: server metadata for the photo to render.
///   - `isExpanded`: when `true`, renders an invisible placeholder so the
///     overlay can occupy the slot.
///   - `onTap`: invoked when the user taps the thumbnail.
struct ComparisonPhotoCell: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if isExpanded {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.BG.secondary.opacity(0.4))
            } else if let img = thumb {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.BG.secondary)
                    .overlay { ProgressView().tint(Theme.FG.tertiary) }
            }
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if thumb != nil { onTap() } }
        .task(id: meta.id) {
            thumb = await store.thumb(meta)
        }
    }
}

/// Dashed-outline empty slot rendered when one side of a tag pair has no
/// photo on the chosen date.
struct ComparisonPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Theme.FG.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.BG.secondary.opacity(0.4))
            )
            .overlay {
                Text("No photo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
    }
}
