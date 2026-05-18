/// Full-screen viewer for an individual progress photo.
///
/// Hosts `ProgressPhotoDetailView`, which fetches the full-resolution image
/// for a `ProgressPhotoMetadata` row from `ProgressPhotoStore`, supports
/// pinch-to-zoom, and exposes a trash action that deletes the photo and
/// dismisses.
import SwiftUI
import UIKit

/// Modal viewer showing one progress photo with zoom + delete affordances.
struct ProgressPhotoDetailView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss
    let meta: ProgressPhotoMetadata

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await store.delete(meta)
                            dismiss()
                        }
                    } label: { Image(systemName: "trash") }
                }
            }
            .task { image = await store.full(meta) }
        }
    }

    private var title: String {
        let tagName = tagStore.tag(id: meta.tagId)?.name ?? "Photo"
        let dateStr = meta.date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(tagName) · \(dateStr)"
    }
}
