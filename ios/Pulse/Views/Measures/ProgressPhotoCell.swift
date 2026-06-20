/// Grid cell representing one stored progress photo.
///
/// Hosts `ProgressPhotoCell`, which lazily fetches a thumbnail from
/// `ProgressPhotoStore`, displays the tag name as a badge on the top-left,
/// and forwards taps to the parent so it can present the fullscreen viewer.
/// Also exposes a context menu for Delete.
import SwiftUI
import UIKit

/// Single tile in the flat photo grid.
/// - Parameters:
///   - `meta`: server metadata for the photo this cell represents.
///   - `tagName`: human-readable tag label shown as a top-left badge.
///   - `onTap`: invoked when the user taps the thumbnail.
struct ProgressPhotoCell: View {
    @Environment(ProgressPhotoStore.self) private var store
    let meta: ProgressPhotoMetadata
    let tagName: String
    let onTap: () -> Void

    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail
            tagBadge
                .padding(8)
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if thumb != nil { onTap() } }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task {
                    await store.delete(meta)
                    thumb = nil
                }
            }
        }
        .task(id: meta.sha256) {
            thumb = await store.thumb(meta)
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

    private var tagBadge: some View {
        Text(tagName)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
