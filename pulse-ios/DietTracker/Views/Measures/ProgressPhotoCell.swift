/// Grid cell representing one stored progress photo.
///
/// Hosts `ProgressPhotoCell`, which lazily fetches a thumbnail from
/// `ProgressPhotoStore`, presents `ProgressPhotoDetailView` on tap, and
/// provides a context menu for Delete. Used inside the per-tag rows on
/// `ProgressPhotosView`.
import SwiftUI
import UIKit

/// Single tile in the photo grid showing the cached thumbnail for one photo.
struct ProgressPhotoCell: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata

    @State private var thumb: UIImage?
    @State private var showDetail = false

    var body: some View {
        ZStack {
            if let img = thumb {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.BG.secondary)
                    .overlay {
                        ProgressView().tint(Theme.FG.tertiary)
                    }
            }
        }
        .aspectRatio(4.0/5.0, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if thumb != nil { showDetail = true } }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task {
                    await store.delete(meta)
                    thumb = nil
                }
            }
        }
        .sheet(isPresented: $showDetail) {
            ProgressPhotoDetailView(meta: meta)
        }
        .task(id: meta.sha256) {
            thumb = await store.thumb(meta)
        }
    }
}
