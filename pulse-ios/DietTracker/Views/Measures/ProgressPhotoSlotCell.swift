/// Grid cell representing one progress-photo slot for a given date.
///
/// Hosts `ProgressPhotoSlotCell`, which lazily fetches a thumbnail from
/// `ProgressPhotoStore`, renders an empty dashed placeholder if absent,
/// presents `ProgressPhotoDetailView` on tap, and provides a context menu
/// for Replace / Delete. Used inside the 2×2 grid on `ProgressPhotosView`.
import SwiftUI
import UIKit

/// Single slot tile in the photo grid showing either a cached thumb or a placeholder.
///
/// Inputs:
/// - date: the date being displayed.
/// - slot: the slot represented by this cell.
/// - onReplace: callback invoked when the user picks "Replace" in the context menu.
struct ProgressPhotoSlotCell: View {
    @Environment(ProgressPhotoStore.self) private var store
    let date: Date
    let slot: ProgressPhotoSlot
    var onReplace: () -> Void

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
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(Theme.FG.tertiary)
                    .overlay {
                        Text(slot.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
            }
        }
        .aspectRatio(4.0/5.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            Text(slot.displayName)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
                .opacity(thumb == nil ? 0 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if thumb != nil { showDetail = true } }
        .contextMenu {
            Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task {
                    await store.delete(date: date, slot: slot)
                    thumb = nil
                }
            }
        }
        .sheet(isPresented: $showDetail) {
            ProgressPhotoDetailView(date: date, slot: slot)
        }
        .task(id: storageKey) {
            await loadThumb()
        }
    }

    private var storageKey: String {
        if case .synced(let sha) = store.status(date: date, slot: slot) {
            return sha
        }
        return "empty"
    }

    /// Asks the store for the cached thumbnail and assigns it to `thumb`.
    private func loadThumb() async {
        thumb = await store.thumb(date: date, slot: slot)
    }
}
