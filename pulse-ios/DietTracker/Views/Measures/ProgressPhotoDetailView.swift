/// In-place fullscreen viewer for a tapped progress photo.
///
/// Hosts `ProgressPhotoDetailView`, rendered as an overlay above
/// `ProgressPhotosView`'s grid. Uses `matchedGeometryEffect` keyed on
/// `meta.id` to animate the grid cell into a full-bleed view. Loads the
/// full-resolution image from `ProgressPhotoStore`, supports pinch-to-zoom,
/// and exposes a trash action that deletes the photo and dismisses. A tap
/// anywhere on the backdrop collapses back into the grid.
import SwiftUI
import UIKit

/// Fullscreen overlay viewer for one progress photo.
/// - Parameters:
///   - `meta`: server metadata for the photo to display.
///   - `tagName`: human-readable tag label shown in the header.
///   - `namespace`: shared `Namespace.ID` used to animate from the
///     originating `ProgressPhotoCell`.
///   - `onClose`: invoked to collapse the overlay back into the grid.
struct ProgressPhotoDetailView: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
    let tagName: String
    let namespace: Namespace.ID
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
                .onTapGesture { onClose() }

            imageLayer

            header
        }
        .task { image = await store.full(meta) }
    }

    @ViewBuilder
    private var imageLayer: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1.0, min(4.0, $0)) }
                            .onEnded { _ in withAnimation { if scale < 1.0 { scale = 1.0 } } }
                    )
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .matchedGeometryEffect(id: meta.id, in: namespace)
        .onTapGesture { onClose() }
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
            Button(role: .destructive) {
                Task {
                    await store.delete(meta)
                    onClose()
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var title: String {
        let dateStr = meta.date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(tagName) · \(dateStr)"
    }
}
