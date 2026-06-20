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
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    let initialDate: Date

    @State private var dateA: Date
    @State private var dateB: Date
    @State private var expanded: ExpandedPhoto?
    @State private var isLoading: Bool = false
    @State private var reloadTask: Task<Void, Never>?
    /// Logged weight on each side's date, refreshed alongside the photo
    /// reconcile so the column captions stay in sync with the date pickers.
    @State private var weightA: WeightEntry?
    @State private var weightB: WeightEntry?

    private struct ExpandedPhoto: Identifiable, Equatable {
        let id: UUID
        let meta: ProgressPhotoMetadata
        let tagName: String
    }

    /// Caption date style ("Jun 13"), hoisted out of the render path so the
    /// `FormatStyle` isn't rebuilt on every pass while a picker is scrubbed.
    private static let dayFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day()

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
        }
        .fullScreenCover(item: $expanded) { exp in
            ProgressPhotoDetailView(
                meta: exp.meta,
                tagName: exp.tagName,
                onClose: { expanded = nil }
            )
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
        HStack(alignment: .top, spacing: 12) {
            pickerColumn(date: $dateA, weight: weightA)
            pickerColumn(date: $dateB, weight: weightB)
        }
    }

    /// One side's date picker with a caption beneath it showing that date and
    /// the weight logged on it (or "no weight" when none was recorded).
    /// - Parameters:
    ///   - date: two-way binding to this side's selected date.
    ///   - weight: the weight entry logged on `date`, if any.
    /// - Returns: a centered column view.
    private func pickerColumn(date: Binding<Date>, weight: WeightEntry?) -> some View {
        VStack(spacing: 6) {
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.CTP.mauve)
            Text(caption(date: date.wrappedValue, weight: weight))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Builds the "<date> · <weight>" caption shown under a date picker.
    /// - Parameters:
    ///   - date: the column's selected date.
    ///   - weight: the weight entry logged on `date`, if any.
    /// - Returns: a single-line caption string.
    private func caption(date: Date, weight: WeightEntry?) -> String {
        let day = date.formatted(Self.dayFormat)
        let unit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        if let weight {
            return "\(day) · \(WeightFormatter.display(lb: weight.weightLb, in: unit))"
        }
        return "\(day) · no weight"
    }

    private func reload() async {
        isLoading = true
        let lo = min(dateA, dateB)
        let hi = max(dateA, dateB)
        await store.reconcile(from: lo, to: hi)
        await loadWeights()
        if !Task.isCancelled { isLoading = false }
    }

    /// Fetches the logged weight for each side's date in parallel, tolerating a
    /// missing entry (the column then shows "no weight"). Skips applying results
    /// when the surrounding reload was cancelled by a newer date change.
    /// - Returns: nothing; updates `weightA` / `weightB` in place.
    private func loadWeights() async {
        guard let client = auth.makeClient() else { return }
        async let a = try? client.getWeight(date: dateA)
        async let b = try? client.getWeight(date: dateB)
        let (resultA, resultB) = await (a, b)
        if Task.isCancelled { return }
        weightA = resultA
        weightB = resultB
    }
}

// MARK: - Rows

private extension ProgressPhotoComparisonView {
    /// Latest photo per tag for the given date. When multiple uploads share
    /// `(date, tagId)`, keeps the one with the largest `updatedAt`.
    /// - Parameter date: the calendar day to look up.
    /// - Returns: map from `tagId` to the most recent photo metadata.
    func latestByTag(on date: Date) -> [UUID: ProgressPhotoMetadata] {
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
    func orderedTagIds(_ a: [UUID: ProgressPhotoMetadata], _ b: [UUID: ProgressPhotoMetadata]) -> [UUID] {
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
    var rows: some View {
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

    func tagRow(tagId: UUID, leftMeta: ProgressPhotoMetadata?, rightMeta: ProgressPhotoMetadata?) -> some View {
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
    func comparisonSlot(meta: ProgressPhotoMetadata?, tagName: String) -> some View {
        if let meta {
            ComparisonPhotoCell(
                meta: meta,
                onTap: {
                    expanded = ExpandedPhoto(id: meta.id, meta: meta, tagName: tagName)
                }
            )
        } else {
            ComparisonPlaceholder()
        }
    }
}

/// Slimmed-down photo tile for the comparison grid. No tag badge (the row
/// header already labels the tag) and no context menu (delete belongs in the
/// main photos view, not here). Tapping opens the shared fullscreen viewer.
/// - Parameters:
///   - `meta`: server metadata for the photo to render.
///   - `onTap`: invoked when the user taps the thumbnail.
struct ComparisonPhotoCell: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
    let onTap: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let img = thumb {
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
