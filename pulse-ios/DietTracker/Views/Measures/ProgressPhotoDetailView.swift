import SwiftUI
import UIKit

struct ProgressPhotoDetailView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let slot: ProgressPhotoSlot

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
            .navigationTitle("\(slot.displayName) · \(date.formatted(.dateTime.month(.abbreviated).day().year()))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await store.delete(date: date, slot: slot)
                            dismiss()
                        }
                    } label: { Image(systemName: "trash") }
                }
            }
            .task { image = await store.full(date: date, slot: slot) }
        }
    }
}
