/// Container create/edit sheet for the Prep flow.
///
/// Hosts `ContainerEditView`, which renders the form for naming a container,
/// setting its tare weight, and attaching a photo (camera or photo library).
/// Camera capture uses the shared `CameraCaptureView` bridge to
/// `UIImagePickerController`.
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
                        SectionCard(header: "Photo") { photoSection }

                        SectionCard(header: "Details") {
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
                CameraCaptureView(
                    onCapture: { image in
                        previewImage = image
                        model?.setNewPhoto(uiImage: image)
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
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
