/// Container create/edit sheet for the Prep flow.
///
/// Hosts `ContainerEditView`, which renders the form for naming a container,
/// setting its tare weight, and attaching a photo (camera or photo library).
/// Also provides the private `CameraPicker` `UIViewControllerRepresentable`
/// bridge to `UIImagePickerController` used by the photo section.
///
/// Bound to `ContainerEditModel` for state/save logic; presented by
/// `ContainersListView` and (indirectly) by `PrepView`.
import PhotosUI
import SwiftUI
import UIKit

/// Modal sheet that creates a new container or edits an existing one.
///
/// Inputs:
/// - existing: the `Container` being edited, or `nil` to create a new one.
/// - onSaved: callback invoked with the saved container's id after a
///   successful save, before the sheet dismisses.
struct ContainerEditView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let existing: Container?
    let onSaved: (UUID) -> Void

    @State private var model: ContainerEditModel?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        section(header: "Photo") { photoSection }

                        section(header: "Details") {
                            textRow {
                                TextField(
                                    "",
                                    text: Binding(
                                        get: { model?.name ?? "" },
                                        set: { model?.name = $0 }
                                    ),
                                    prompt: Text("Name").foregroundStyle(Theme.FG.tertiary)
                                )
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.FG.primary)
                                .tint(Theme.CTP.mauve)
                                .textInputAutocapitalization(.words)
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            textRow {
                                HStack {
                                    TextField(
                                        "",
                                        text: Binding(
                                            get: { model?.tareWeightText ?? "" },
                                            set: { model?.tareWeightText = $0 }
                                        ),
                                        prompt: Text("Tare weight").foregroundStyle(Theme.FG.tertiary)
                                    )
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(Theme.FG.primary)
                                    .tint(Theme.CTP.mauve)
                                    .keyboardType(.decimalPad)
                                    Text("g")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.FG.secondary)
                                }
                            }
                        }

                        if let err = model?.error {
                            Text(err.userMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.CTP.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(existing == nil ? "New container" : "Edit container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
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
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        (model?.isValid == true && model?.saving != true)
                            ? Theme.CTP.mauve
                            : Theme.FG.tertiary
                    )
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
        .preferredColorScheme(.dark)
        .task {
            if model == nil { model = ContainerEditModel(existing: existing, auth: auth) }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        VStack(spacing: 0) {
            ZStack {
                if let img = previewImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let id = model?.existingPhotoId, let client = auth.makeClient() {
                    AuthorizedAsyncImage(
                        request: client.containerPhotoRequest(id: id, size: .full),
                        content: { $0.resizable().scaledToFill() },
                        placeholder: { Theme.CTP.surface0 }
                    )
                } else {
                    ZStack {
                        Theme.CTP.surface0
                        VStack(spacing: 6) {
                            Image(systemName: "camera")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.CTP.mauve.opacity(0.6))
                            Text("No photo")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                    }
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipped()

            Rectangle().fill(Theme.separator).frame(height: 0.5)

            HStack(spacing: 8) {
                photoActionButton(label: "Camera", systemImage: "camera") {
                    showCamera = true
                }
                photoPickerButton

                if model?.existingPhotoId != nil || previewImage != nil {
                    Spacer()
                    photoActionButton(
                        label: "Remove",
                        systemImage: "trash",
                        tint: Theme.CTP.red
                    ) {
                        previewImage = nil
                        model?.clearPhoto()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Pill-shaped action button used for camera/remove actions in the photo section.
    ///
    /// Inputs:
    /// - label: visible text label.
    /// - systemImage: SF Symbols name shown to the left of the label.
    /// - tint: foreground and background tint color.
    /// - action: closure executed on tap.
    ///
    /// Outputs: a styled `View` representing the button.
    private func photoActionButton(
        label: String,
        systemImage: String,
        tint: Color = Theme.CTP.mauve,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var photoPickerButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                Text("Library")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.CTP.mauve)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.CTP.mauve.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.CTP.mauve.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    /// Wraps a card-styled content block under an uppercase section header.
    ///
    /// Inputs:
    /// - header: section title shown above the card.
    /// - content: view builder for the card body.
    ///
    /// Outputs: a `View` containing the header label and its themed card body.
    @ViewBuilder
    private func section<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .ctpCard()
                .padding(.horizontal, 16)
        }
    }

    /// Adds the row's standard horizontal/vertical padding around its content.
    ///
    /// Inputs:
    /// - content: view builder for the row's inner content.
    ///
    /// Outputs: the content view padded to row dimensions.
    @ViewBuilder
    private func textRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    /// Loads the selected `PhotosPickerItem` as `UIImage` and hands it to the model.
    ///
    /// Inputs:
    /// - item: the picked photo item; if `nil`, the call is a no-op.
    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let img = UIImage(data: data) {
            previewImage = img
            model?.setNewPhoto(uiImage: img)
        }
    }
}

/// SwiftUI bridge to `UIImagePickerController` for camera capture in the container edit flow.
///
/// Inputs:
/// - onCaptured: callback invoked with the captured `UIImage` once the user
///   takes a photo and the picker dismisses.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void

    /// Creates the delegate coordinator wired to forward captures to `onCaptured`.
    ///
    /// Outputs: a `Coordinator` instance acting as the picker's delegate.
    func makeCoordinator() -> Coordinator { Coordinator(onCaptured: onCaptured) }

    /// Builds the underlying `UIImagePickerController` configured for camera input.
    ///
    /// Inputs:
    /// - context: SwiftUI representable context that supplies the coordinator.
    ///
    /// Outputs: a configured `UIImagePickerController`.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    /// No-op; the picker's configuration never changes after creation.
    ///
    /// Inputs:
    /// - uiViewController: the hosted picker.
    /// - context: SwiftUI representable context (unused).
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Delegate that forwards camera capture/cancel events to the parent representable.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCaptured: (UIImage) -> Void
        /// Stores the capture callback used when the user finishes picking.
        ///
        /// Inputs:
        /// - onCaptured: closure invoked with the captured image.
        init(onCaptured: @escaping (UIImage) -> Void) { self.onCaptured = onCaptured }
        /// `UIImagePickerControllerDelegate` hook: pulls the original image and dismisses.
        ///
        /// Inputs:
        /// - picker: the active picker controller.
        /// - info: media metadata; `originalImage` is read when present.
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let img = info[.originalImage] as? UIImage { onCaptured(img) }
            picker.dismiss(animated: true)
        }
        /// `UIImagePickerControllerDelegate` hook: dismisses without invoking the callback.
        ///
        /// Inputs:
        /// - picker: the active picker controller.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
