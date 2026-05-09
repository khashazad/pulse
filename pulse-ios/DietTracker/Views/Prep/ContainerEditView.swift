import PhotosUI
import SwiftUI
import UIKit

struct ContainerEditView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let existing: Container?
    let onSaved: (UUID) -> Void

    @State private var model: ContainerEditModel?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") { photoSection }
                Section("Details") {
                    TextField("Name", text: Binding(
                        get: { model?.name ?? "" },
                        set: { model?.name = $0 }
                    ))
                    HStack {
                        TextField("Tare weight", text: Binding(
                            get: { model?.tareWeightText ?? "" },
                            set: { model?.tareWeightText = $0 }
                        ))
                        .keyboardType(.decimalPad)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                if let err = model?.error {
                    Section { Text(err.userMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New container" : "Edit container")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model?.saving == true ? "Saving…" : "Save") {
                        Task {
                            await model?.save()
                            if let id = model?.savedContainerId {
                                onSaved(id)
                                dismiss()
                            }
                        }
                    }
                    .disabled(model?.isValid != true || model?.saving == true)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    previewImage = image
                    model?.setNewPhoto(uiImage: image)
                }
            }
            .onChange(of: pickerItem) { _, newValue in
                Task { await loadPicked(newValue) }
            }
        }
        .task {
            if model == nil { model = ContainerEditModel(existing: existing, settings: settings) }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                if let img = previewImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let id = model?.existingPhotoId, let client = settings.makeClient() {
                    AuthorizedAsyncImage(
                        request: client.containerPhotoRequest(id: id, size: .full),
                        content: { $0.resizable().scaledToFill() },
                        placeholder: { Color.gray.opacity(0.15) }
                    )
                } else {
                    ZStack {
                        Color.gray.opacity(0.15)
                        Image(systemName: "camera").font(.title).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Library", systemImage: "photo")
                }
                .buttonStyle(.bordered)

                if model?.existingPhotoId != nil || previewImage != nil {
                    Spacer()
                    Button(role: .destructive) {
                        previewImage = nil
                        model?.clearPhoto()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            previewImage = img
            model?.setNewPhoto(uiImage: img)
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCaptured: (UIImage) -> Void
        init(onCaptured: @escaping (UIImage) -> Void) { self.onCaptured = onCaptured }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let img = info[.originalImage] as? UIImage { onCaptured(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
