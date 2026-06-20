/// Fullscreen viewer for a tapped progress photo.
///
/// Presented as a `fullScreenCover` over `ProgressPhotosView` /
/// `ProgressPhotoComparisonView`, so it covers the entire window — including
/// the floating tab dock and section chrome — and a dismiss always returns to
/// the exact grid it came from instead of letting a stray tap switch sections.
/// Loads the full-resolution image from `ProgressPhotoStore`, supports
/// pinch-to-zoom, and exposes a trash action that deletes the photo and
/// dismisses. A tap anywhere on the backdrop closes it.
import SwiftUI
import UIKit

/// Fullscreen viewer for one progress photo.
/// - Parameters:
///   - `meta`: server metadata for the photo to display.
///   - `tagName`: human-readable tag label shown in the header.
///   - `onClose`: invoked to dismiss the viewer back to the grid.
struct ProgressPhotoDetailView: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
    let tagName: String
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
        // Keyed on the photo id so a metadata swap restarts the load instead
        // of leaving the previous photo's image on screen.
        .task(id: meta.id) { image = await store.full(meta) }
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
