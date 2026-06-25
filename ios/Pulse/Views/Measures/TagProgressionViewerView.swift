/// Paged fullscreen viewer for one tag's progression.
///
/// Presented as a `fullScreenCover` over `TagProgressionGalleryView` so it
/// covers the entire window (dock + chrome included). Pages horizontally across
/// the whole tag set via a `TabView`, loads each full-resolution image from the
/// shared `ProgressPhotoStore`, supports pinch-to-zoom, and exposes a delete
/// that removes the photo and advances (or closes when empty).
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
    /// Guards the trash action so a rapid double-tap can't spawn two concurrent
    /// delete tasks (which would fire a redundant DELETE and race the advance).
    @State private var isDeleting = false

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
                    PageImage(meta: meta, onClose: onClose)
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
            .disabled(isDeleting)
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

    /// Deletes the selected photo, then advances selection to the neighbor the
    /// model reports, or closes the viewer when the set is now empty.
    /// - Returns: Void.
    private func deleteCurrent() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            if let next = await model.deleteAndAdvance(from: selection) {
                selection = next
            } else {
                onClose()
            }
            isDeleting = false
        }
    }
}

/// One full-resolution page inside the paged viewer. Loads its image straight
/// from the shared `ProgressPhotoStore` cache, keyed on the photo id.
private struct PageImage: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
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
            image = await store.full(meta)
        }
    }
}
