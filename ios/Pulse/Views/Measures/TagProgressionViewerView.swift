/// Paged fullscreen viewer for one tag's progression.
///
/// Presented as a `fullScreenCover` over `TagProgressionGalleryView` so it
/// covers the entire window (dock + chrome included). Pages horizontally across
/// the whole tag set via a `TabView`, loads each full-resolution image from the
/// shared store through `TagProgressionModel`, supports pinch-to-zoom, and
/// exposes a delete that removes the photo and advances (or closes when empty).
/// A tap on the backdrop closes it.
import SwiftUI
import UIKit

/// Swipe-through fullscreen viewer across a tag's photos.
/// - Parameters:
///   - model: the tag-progression model whose `photos` drive the pages.
///   - initialPhotoId: id of the photo to open on first.
///   - onClose: invoked to dismiss back to the grid.
struct TagProgressionViewerView: View {
    let model: TagProgressionModel
    let onClose: () -> Void

    @State private var selection: UUID

    /// Builds the viewer starting on a chosen photo.
    /// - Parameters:
    ///   - model: the tag-progression model.
    ///   - initialPhotoId: id of the photo to show first.
    ///   - onClose: dismissal callback.
    init(model: TagProgressionModel, initialPhotoId: UUID, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _selection = State(initialValue: initialPhotoId)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
                .onTapGesture { onClose() }

            TabView(selection: $selection) {
                ForEach(model.photos) { meta in
                    PageImage(meta: meta, loader: { await model.full(meta) }, onClose: onClose)
                        .tag(meta.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            header
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
            Spacer()
            Button(role: .destructive) { deleteCurrent() } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Header title for the currently selected page (tag · date), or the tag
    /// name alone when no photo matches (transient during deletes).
    private var title: String {
        guard let meta = model.photos.first(where: { $0.id == selection }) else { return model.tag.name }
        let dateStr = meta.date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(model.tag.name) · \(dateStr)"
    }

    /// Deletes the selected photo, then advances selection to a neighbor or
    /// closes the viewer when the set is now empty.
    /// - Returns: Void.
    private func deleteCurrent() {
        guard let idx = model.photos.firstIndex(where: { $0.id == selection }) else { return }
        let meta = model.photos[idx]
        Task {
            await model.delete(meta)
            let remaining = model.photos
            if remaining.isEmpty { onClose(); return }
            let nextIdx = min(idx, remaining.count - 1)
            selection = remaining[nextIdx].id
        }
    }
}

/// One full-resolution page inside the paged viewer.
private struct PageImage: View {
    let meta: ProgressPhotoMetadata
    let loader: () async -> UIImage?
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1.0, min(4.0, baseScale * $0)) }
                            .onEnded { _ in baseScale = scale }
                    )
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { onClose() }
        .task(id: meta.id) {
            scale = 1.0
            baseScale = 1.0
            image = await loader()
        }
    }
}
