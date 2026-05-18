/// Capture flow for adding progress photos under a single chosen tag.
///
/// Hosts `PhotoCaptureSession`, which lets the user gather one or more photos
/// (camera or library) for a `(date, tag)` pair and uploads each via
/// `ProgressPhotoStore.upload(date:tagId:imageData:)`. To attach a different
/// tag, the user reopens the capture flow from `ProgressPhotosView` and
/// picks again.
import PhotosUI
import SwiftUI
import UIKit

struct PhotoCaptureSession: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let tag: ProgressPhotoTag

    private struct CapturedPhoto: Identifiable, Hashable {
        let id = UUID()
        let image: UIImage
        static func == (lhs: CapturedPhoto, rhs: CapturedPhoto) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @State private var captured: [CapturedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var uploading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header
                grid
                Spacer()
                uploadButton
            }
            .padding(16)
            .background(Theme.BG.primary.ignoresSafeArea())
            .navigationTitle(tag.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(
                    onCapture: { image in
                        captured.append(CapturedPhoto(image: image))
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadPickerSelection(items) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Add to \(tag.name) on \(date.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.FG.secondary)
            Spacer()
            Button { showCamera = true } label: {
                Image(systemName: "camera.fill").foregroundStyle(Theme.CTP.mauve)
            }
            PhotosPicker(
                selection: $pickerItems,
                maxSelectionCount: 8,
                matching: .images
            ) {
                Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.CTP.mauve)
            }
        }
    }

    private var grid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return ScrollView {
            if captured.isEmpty {
                Text("Tap the camera or library icon above to add photos.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(captured) { photo in
                        Image(uiImage: photo.image)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(4.0/5.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    captured.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, Theme.CTP.red)
                                }
                                .padding(6)
                            }
                    }
                }
            }
        }
    }

    private var uploadButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                if uploading { ProgressView().tint(.white) }
                Text(uploading ? "Uploading…" : "Upload (\(captured.count))")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(captured.isEmpty ? Theme.BG.secondary : Theme.CTP.mauve, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(captured.isEmpty || uploading)
    }

    private func loadPickerSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                await MainActor.run { captured.append(CapturedPhoto(image: img)) }
            }
        }
        pickerItems = []
    }

    private func submit() async {
        uploading = true
        defer { uploading = false }
        for photo in captured {
            guard let jpeg = photo.image.jpegData(compressionQuality: 0.85) else { continue }
            await store.upload(date: date, tagId: tag.id, imageData: jpeg)
        }
        dismiss()
    }
}
