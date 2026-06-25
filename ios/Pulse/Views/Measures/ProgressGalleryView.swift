/// Multi-tag progress-photo gallery.
///
/// Entered directly from the Photos sub-tab (no tag prompt). A tag-chip bar at
/// the top selects which tag's full history fills the 3-column grid; switching
/// chips reloads instantly. Each cell shows the photo's date and that day's
/// logged weight. "Select" enters multi-select; choosing two photos navigates
/// straight to the stacked pair comparison. Tapping a cell (when not selecting)
/// opens the swipe-through fullscreen viewer.
import SwiftUI

/// Tag-switchable, weight-annotated gallery of all progress photos.
struct ProgressGalleryView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(AuthSession.self) private var auth
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    @State private var selectedTag: ProgressPhotoTag?
    @State private var model: TagProgressionModel?
    @State private var weightIndex: [Date: WeightEntry] = [:]
    @State private var viewer: ProgressPhotoMetadata?
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []
    @State private var comparison: ComparisonRequest?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 10) {
                if !tagStore.tags.isEmpty {
                    TagChipBar(tags: tagStore.tags, selectedId: selectedTag?.id) { select($0) }
                        .padding(.top, 8)
                }
                content
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model?.photos.isEmpty == false {
                    Button(isSelecting ? "Cancel" : "Select") { setSelecting(!isSelecting) }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .navigationDestination(item: $comparison) { req in
            PhotoPairComparisonView(older: req.older, newer: req.newer, initialTag: req.initialTag)
        }
        .task {
            if tagStore.tags.isEmpty { await tagStore.reload() }
            if selectedTag == nil, let first = tagStore.tags.first { select(first) }
        }
        .refreshable { await reload() }
        .fullScreenCover(item: $viewer) { meta in
            if let model {
                TagProgressionViewerView(model: model, initialPhotoId: meta.id, onClose: { viewer = nil })
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle, .loading:
            ProgressView().tint(Theme.CTP.mauve)
            Spacer()
        case .failed(let error):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load photos",
                description: error.userMessage
            )
            Spacer()
        case .loaded(let photos):
            if photos.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle",
                    title: "No photos yet",
                    description: tagStore.tags.isEmpty
                        ? "Add a tag and some photos to see them here."
                        : "No photos for this tag yet."
                )
                Spacer()
            } else {
                grid(photos)
            }
        }
    }

    /// Renders the selected tag's photos in a 3-column lazy grid with date +
    /// weight captions.
    /// - Parameter photos: newest-first metadata for the selected tag.
    /// - Returns: the scrollable grid.
    private func grid(_ photos: [ProgressPhotoMetadata]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if isSelecting {
                    Text("\(selectedIds.count) selected · pick 2 to compare")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.FG.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos) { meta in
                        GalleryCell(
                            meta: meta,
                            weight: weightIndex[Calendar.current.startOfDay(for: meta.date)],
                            unitRaw: displayUnitRaw,
                            isSelecting: isSelecting,
                            isSelected: selectedIds.contains(meta.id),
                            onTap: { viewer = meta },
                            onToggle: { toggleSelection(meta) },
                            onDelete: { Task { await model?.delete(meta) } }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
        .onChange(of: photos.map(\.id)) { _, ids in
            selectedIds = selectedIds.intersection(Set(ids))
        }
    }

    // MARK: actions

    /// Selects a tag: rebuilds the per-tag model and reloads its photos + weights.
    /// - Parameter tag: the tag to show.
    private func select(_ tag: ProgressPhotoTag) {
        guard tag.id != selectedTag?.id else { return }
        selectedTag = tag
        selectedIds.removeAll()
        let m = TagProgressionModel(tag: tag, auth: auth, store: store)
        model = m
        Task {
            await m.load()
            await loadWeights(for: m.photos)
        }
    }

    /// Reloads the current tag's photos and weight index (pull-to-refresh).
    private func reload() async {
        guard let model else { return }
        await model.load()
        await loadWeights(for: model.photos)
    }

    /// Fetches weights covering the photos' date span (in ≤366-day windows to
    /// respect the server range cap) and indexes them by day.
    /// - Parameter photos: the loaded photos whose dates bound the weight fetch.
    private func loadWeights(for photos: [ProgressPhotoMetadata]) async {
        guard let client = auth.makeClient(),
              let minDate = photos.map(\.date).min(),
              let maxDate = photos.map(\.date).max() else {
            weightIndex = [:]
            return
        }
        var entries: [WeightEntry] = []
        for window in dateRangeWindows(from: minDate, to: maxDate) {
            if let chunk = try? await client.listWeightEntries(from: window.start, to: window.end) {
                entries.append(contentsOf: chunk)
            }
        }
        weightIndex = indexWeightsByDay(entries)
    }

    /// Enters/exits selection mode, clearing checks on exit.
    /// - Parameter value: target selection-mode state.
    private func setSelecting(_ value: Bool) {
        isSelecting = value
        if !value { selectedIds.removeAll() }
    }

    /// Toggles one photo's selection; when two are selected, opens the comparison.
    /// - Parameter meta: the tapped photo.
    private func toggleSelection(_ meta: ProgressPhotoMetadata) {
        if selectedIds.contains(meta.id) {
            selectedIds.remove(meta.id)
        } else {
            selectedIds.insert(meta.id)
        }
        if selectedIds.count == 2 { openComparison() }
    }

    /// Builds the comparison request from the two selected photos and navigates.
    private func openComparison() {
        guard let tag = selectedTag else { return }
        let selected = (model?.photos ?? []).filter { selectedIds.contains($0.id) }
        guard selected.count == 2 else { return }
        let pair = orderedPair(selected[0], selected[1])
        comparison = ComparisonRequest(older: pair.older, newer: pair.newer, initialTag: tag)
        setSelecting(false)
    }
}

// MARK: - Navigation value

/// Navigation payload for the stacked pair comparison: the two selected photos
/// (chronological) plus the tag selected when the pair was chosen.
struct ComparisonRequest: Hashable, Identifiable {
    let id: UUID
    let older: ProgressPhotoMetadata
    let newer: ProgressPhotoMetadata
    let initialTag: ProgressPhotoTag

    /// - Parameters:
    ///   - older: the earlier selected photo.
    ///   - newer: the later selected photo.
    ///   - initialTag: the tag the pair was selected under.
    init(older: ProgressPhotoMetadata, newer: ProgressPhotoMetadata, initialTag: ProgressPhotoTag) {
        self.older = older
        self.newer = newer
        self.initialTag = initialTag
        self.id = UUID(uuid: zipUUIDBytes(older.id, newer.id))
    }
}

/// XORs two UUIDs' bytes into a stable, order-independent identity.
/// - Parameters:
///   - lhs: first id.
///   - rhs: second id.
/// - Returns: a deterministic combined uuid byte tuple.
private func zipUUIDBytes(_ lhs: UUID, _ rhs: UUID) -> uuid_t {
    let a = lhs.uuid
    let b = rhs.uuid
    return (
        a.0 ^ b.0, a.1 ^ b.1, a.2 ^ b.2, a.3 ^ b.3,
        a.4 ^ b.4, a.5 ^ b.5, a.6 ^ b.6, a.7 ^ b.7,
        a.8 ^ b.8, a.9 ^ b.9, a.10 ^ b.10, a.11 ^ b.11,
        a.12 ^ b.12, a.13 ^ b.13, a.14 ^ b.14, a.15 ^ b.15
    )
}

// MARK: - Cell

/// One gallery tile: thumbnail with optional selection badge, plus a date and
/// (when logged) that day's weight beneath it.
private struct GalleryCell: View {
    @Environment(ProgressPhotoStore.self) private var store

    let meta: ProgressPhotoMetadata
    let weight: WeightEntry?
    let unitRaw: String
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 3) {
            interactiveThumbnail
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            Text(meta.date.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
            if let weightText {
                Text(weightText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.FG.tertiary)
                    .lineLimit(1)
            }
        }
        .task(id: meta.sha256) { thumb = await store.thumb(meta) }
    }

    /// The weight line, or `nil` when no weight was logged that day.
    private var weightText: String? {
        guard let weight else { return nil }
        let unit = WeightUnit(rawValue: unitRaw) ?? .lb
        return WeightFormatter.display(lb: weight.weightLb, in: unit)
    }

    @ViewBuilder
    private var interactiveThumbnail: some View {
        if isSelecting {
            thumbnailWithBadge.onTapGesture(perform: onToggle)
        } else {
            thumbnailWithBadge
                .onTapGesture { if thumb != nil { onTap() } }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                }
        }
    }

    private var thumbnailWithBadge: some View {
        thumbnail.overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.CTP.mauve : Theme.FG.secondary)
                    .padding(6)
                    .background(Circle().fill(Theme.BG.primary.opacity(0.82)))
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
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
}
