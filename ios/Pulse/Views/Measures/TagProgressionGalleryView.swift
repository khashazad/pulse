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
    @State private var viewer: ViewerTarget?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    /// Builds the gallery for a single tag.
    /// - Parameter tag: the progress-photo tag whose full history this view shows.
    init(tag: ProgressPhotoTag) {
        self.tag = tag
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let m = TagProgressionModel(tag: tag, auth: auth, store: store)
                model = m
                await m.load()
            }
        }
        .refreshable { await model?.load() }
        .fullScreenCover(item: $viewer) { target in
            if let model {
                TagProgressionViewerView(
                    model: model,
                    initialPhotoId: target.id,
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
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(photos) { meta in
                    TagProgressionCell(
                        meta: meta,
                        onTap: { viewer = ViewerTarget(id: meta.id) },
                        onDelete: { Task { await model?.delete(meta) } }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
    }
}

// MARK: - Private helpers

/// Thin `Identifiable` wrapper for `UUID` so it can drive `fullScreenCover(item:)`.
private struct ViewerTarget: Identifiable {
    let id: UUID
}

/// One tile in the tag-progression grid: square thumbnail + date caption.
private struct TagProgressionCell: View {
    @Environment(ProgressPhotoStore.self) private var store

    let meta: ProgressPhotoMetadata
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { if thumb != nil { onTap() } }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                }
            Text(meta.date.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.FG.secondary)
                .lineLimit(1)
        }
        .task(id: meta.sha256) { thumb = await store.thumb(meta) }
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
