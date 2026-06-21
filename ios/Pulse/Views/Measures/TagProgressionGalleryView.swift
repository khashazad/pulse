/// Full-history grid of one tag's progress photos.
///
/// Builds its own `TagProgressionModel` from the environment, fetches the tag's
/// all-time photos, and renders them newest-first in a 3-column grid with a
/// date caption under each thumbnail. Tapping a cell opens the swipe-through
/// `TagProgressionViewerView`. Pull-to-refresh reloads. Pushed onto the Measures
/// navigation stack, so the floating dock auto-hides while it is shown.
import SwiftUI

/// Newest-first 3-column gallery for one progress-photo tag.
struct TagProgressionGalleryView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(AuthSession.self) private var auth

    let tag: ProgressPhotoTag

    @State private var model: TagProgressionModel?
    @State private var viewer: ProgressPhotoMetadata?
    @State private var isSelecting: Bool
    @State private var selectedIds: Set<UUID> = []
    @State private var comparePair: PhotoPair?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    /// Builds the gallery for a single tag.
    /// - Parameters:
    ///   - tag: the progress-photo tag whose full history this view shows.
    ///   - initiallySelecting: initial selection-mode state; defaults to normal browsing.
    init(tag: ProgressPhotoTag, initiallySelecting: Bool = false) {
        self.tag = tag
        _isSelecting = State(initialValue: initiallySelecting)
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Compare") { compareSelected() }
                        .disabled(selectedIds.count != 2)
                        .foregroundStyle(Theme.CTP.mauve)
                }
                Button(isSelecting ? "Cancel" : "Select") {
                    setSelecting(!isSelecting)
                }
                .foregroundStyle(Theme.CTP.mauve)
            }
        }
        .navigationDestination(item: $comparePair) { pair in
            PhotoPairComparisonView(
                older: pair.older,
                newer: pair.newer,
                tagName: pair.tagName
            )
        }
        .task {
            if model == nil {
                let m = TagProgressionModel(tag: tag, auth: auth, store: store)
                model = m
                await m.load()
            }
        }
        .refreshable { await model?.load() }
        .fullScreenCover(item: $viewer) { meta in
            if let model {
                TagProgressionViewerView(
                    model: model,
                    initialPhotoId: meta.id,
                    onClose: { viewer = nil }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle, .loading:
            ProgressView().tint(Theme.CTP.mauve)
        case .failed(let error):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load photos",
                description: error.userMessage
            )
        case .loaded(let photos):
            if photos.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle",
                    title: "No photos yet",
                    description: "No photos for this tag yet."
                )
            } else {
                grid(photos)
            }
        }
    }

    /// Renders the loaded photos in a 3-column lazy grid.
    /// - Parameter photos: the newest-first metadata list from the model.
    /// - Returns: a `ScrollView` containing the `LazyVGrid`.
    private func grid(_ photos: [ProgressPhotoMetadata]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if isSelecting {
                    Text("\(selectedIds.count) selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.FG.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(photos) { meta in
                        TagProgressionCell(
                            meta: meta,
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
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
        .onChange(of: photos.map(\.id)) { _, ids in
            selectedIds = selectedIds.intersection(Set(ids))
        }
    }

    /// Enters or exits selection mode, clearing stale checks on exit.
    /// - Parameter value: target selection-mode state.
    private func setSelecting(_ value: Bool) {
        isSelecting = value
        if !value { selectedIds.removeAll() }
    }

    /// Toggles one photo's selected state.
    /// - Parameter meta: selected-grid photo metadata.
    private func toggleSelection(_ meta: ProgressPhotoMetadata) {
        if selectedIds.contains(meta.id) {
            selectedIds.remove(meta.id)
        } else {
            selectedIds.insert(meta.id)
        }
    }

    /// Resolves the selected metadata, orders it chronologically, and pushes the
    /// focused pair comparison when exactly two selected photos still exist.
    private func compareSelected() {
        let selected = model?.photos.filter { selectedIds.contains($0.id) } ?? []
        guard selected.count == 2 else { return }
        let pair = orderedPair(selected[0], selected[1])
        comparePair = PhotoPair(older: pair.older, newer: pair.newer, tagName: tag.name)
    }
}

// MARK: - Private helpers

private struct PhotoPair: Hashable, Identifiable {
    let id: UUID
    let older: ProgressPhotoMetadata
    let newer: ProgressPhotoMetadata
    let tagName: String

    /// Builds a stable navigation identity from the two photo ids.
    /// - Parameters:
    ///   - older: older selected photo.
    ///   - newer: newer selected photo.
    ///   - tagName: shared tag display name.
    init(older: ProgressPhotoMetadata, newer: ProgressPhotoMetadata, tagName: String) {
        self.older = older
        self.newer = newer
        self.tagName = tagName
        self.id = Self.derivedId(older.id, newer.id)
    }

    /// XORs the photo UUID bytes into a stable pair UUID.
    /// - Parameters:
    ///   - lhs: first photo id.
    ///   - rhs: second photo id.
    /// - Returns: deterministic pair id.
    private static func derivedId(_ lhs: UUID, _ rhs: UUID) -> UUID {
        let a = lhs.uuid
        let b = rhs.uuid
        return UUID(uuid: (
            a.0 ^ b.0, a.1 ^ b.1, a.2 ^ b.2, a.3 ^ b.3,
            a.4 ^ b.4, a.5 ^ b.5, a.6 ^ b.6, a.7 ^ b.7,
            a.8 ^ b.8, a.9 ^ b.9, a.10 ^ b.10, a.11 ^ b.11,
            a.12 ^ b.12, a.13 ^ b.13, a.14 ^ b.14, a.15 ^ b.15
        ))
    }
}

/// One tile in the tag-progression grid: square thumbnail + date caption.
private struct TagProgressionCell: View {
    @Environment(ProgressPhotoStore.self) private var store

    let meta: ProgressPhotoMetadata
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            interactiveThumbnail
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            Text(meta.date.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
        }
        .task(id: meta.sha256) { thumb = await store.thumb(meta) }
    }

    @ViewBuilder
    private var interactiveThumbnail: some View {
        if isSelecting {
            thumbnailWithSelectionBadge
                .onTapGesture(perform: onToggle)
        } else {
            thumbnailWithSelectionBadge
                .onTapGesture { if thumb != nil { onTap() } }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                }
        }
    }

    private var thumbnailWithSelectionBadge: some View {
        thumbnail
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    selectionBadge
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

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.CTP.mauve : Theme.FG.secondary)
            .padding(6)
            .background(Circle().fill(Theme.BG.primary.opacity(0.82)))
            .padding(6)
    }
}
