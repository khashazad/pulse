/// Capture flow for adding progress photos with tap-to-tag assignment.
///
/// Hosts `PhotoCaptureSession`, which collects photos from the camera and/or
/// photo library into a 2-up grid. Each photo's top-left corner shows a
/// "Tag" pill that opens a menu of the user's tags; selecting one assigns
/// it to that photo. A separate inline affordance lets the user create a
/// new tag without leaving the sheet. Upload submits every tagged photo
/// via `ProgressPhotoStore.upload(date:tagId:imageData:)` — untagged photos
/// are skipped (and the button is disabled until at least one is tagged).
import PhotosUI
import SwiftUI
import UIKit

struct PhotoCaptureSession: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss
    /// Reads the auto-tag preference so capture can pre-fill tags in pose order.
    @AppStorage(ProgressPhotoTag.autoTagEnabledKey)
    private var autoTagEnabled = ProgressPhotoTag.defaultAutoTagEnabled
    let date: Date

    /// Identity-stable wrapper around a captured `UIImage` plus its
    /// (currently assigned, if any) tag. Not Equatable on purpose — the
    /// custom id-only equality was making SwiftUI's @State diff skip
    /// redraws when only `tagId` changed.
    private struct CapturedPhoto: Identifiable {
        let id = UUID()
        let image: UIImage
        var tagId: UUID?
    }

    @State private var captured: [CapturedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var uploading = false
    @State private var newTagDraft: String = ""
    @State private var showNewTagField = false

    /// Counts only photos whose `tagId` still resolves in `tagStore`. Guards
    /// against stale UUIDs (e.g. a tag deleted between assignment and upload)
    /// being treated as valid assignments and sent to the server.
    private var tagAssignedCount: Int {
        captured.lazy.filter { photo in
            guard let id = photo.tagId else { return false }
            return tagStore.tag(id: id) != nil
        }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                tagBar
                grid
                uploadBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(Theme.BG.primary.ignoresSafeArea())
            .navigationTitle("Add photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showCamera = true } label: {
                            Image(systemName: "camera.fill")
                        }
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: 30,
                            matching: .images
                        ) {
                            Image(systemName: "photo.on.rectangle")
                        }
                    }
                    .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(
                    onCapture: { image in
                        captured.append(CapturedPhoto(image: image))
                        autoAssignTags()
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadPickerSelection(items) }
            }
            .task {
                await tagStore.reload()
                autoAssignTags()
            }
        }
    }

    // MARK: tag bar

    /// Compact header with an inline "new tag" affordance. Tag selection
    /// itself happens per-photo via the "Tag" menu on each cell.
    private var tagBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tap a photo's tag to assign")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                Button {
                    withAnimation { showNewTagField.toggle() }
                } label: {
                    Label("New tag", systemImage: showNewTagField ? "minus.circle" : "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            if showNewTagField {
                newTagRow
            }
        }
    }

    private var newTagRow: some View {
        HStack(spacing: 8) {
            TextField("New tag…", text: $newTagDraft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { Task { await createTag() } }
            Button {
                Task { await createTag() }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.CTP.mauve)
            }
            .disabled(newTagDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: grid

    private var grid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return ScrollView {
            if captured.isEmpty {
                Text("Tap the camera or library icon to add photos.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
            } else {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(captured) { photo in
                        photoCell(photo)
                    }
                }
            }
        }
    }

    /// One photo tile: thumbnail plus an overlay that either shows the
    /// assigned tag chip or a tappable "Tag" menu, and a remove button.
    private func photoCell(_ photo: CapturedPhoto) -> some View {
        let assignedTag = photo.tagId.flatMap { tagStore.tag(id: $0) }
        return Image(uiImage: photo.image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0/5.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                tagMenu(for: photo, assignedTag: assignedTag)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    captured.removeAll { $0.id == photo.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        assignedTag == nil ? Theme.FG.tertiary.opacity(0.4) : .clear,
                        style: StrokeStyle(lineWidth: 1, dash: assignedTag == nil ? [4] : [])
                    )
            )
    }

    /// Top-left tag control for each photo.
    ///
    /// - Untagged: a dashed "Tag" pill that opens a menu of available tags
    ///   (tags already attached to another photo are hidden — each tag is
    ///   one-time-use within this capture session).
    /// - Tagged: a mauve pill with the tag name; the name is itself a Menu
    ///   trigger for swapping to a different tag, and an adjacent X button
    ///   clears the assignment.
    @ViewBuilder
    private func tagMenu(for photo: CapturedPhoto, assignedTag: ProgressPhotoTag?) -> some View {
        if let tag = assignedTag {
            HStack(spacing: 4) {
                Menu {
                    tagPickerItems(for: photo, assignedTag: assignedTag)
                } label: {
                    Text(tag.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.CTP.mauve, in: Capsule())
                }
                Button {
                    clearTag(for: photo.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        } else {
            Menu {
                tagPickerItems(for: photo, assignedTag: nil)
            } label: {
                HStack(spacing: 4) {
                    Text("Tag")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
            }
        }
    }

    /// Menu body shared by tagged and untagged states. Excludes tags
    /// already attached to other photos in the current capture; keeps the
    /// currently-attached tag in the list so the user sees their own
    /// selection (and tapping it is a no-op cheap way to dismiss).
    @ViewBuilder
    private func tagPickerItems(for photo: CapturedPhoto, assignedTag: ProgressPhotoTag?) -> some View {
        let usedElsewhere: Set<UUID> = Set(
            captured.compactMap { other in
                other.id == photo.id ? nil : other.tagId
            }
        )
        ForEach(tagStore.tags) { tag in
            if !usedElsewhere.contains(tag.id) {
                Button(tag.name) {
                    assignTag(tag.id, to: photo.id)
                }
            }
        }
        if assignedTag != nil {
            Divider()
            Button("Unassign", role: .destructive) {
                clearTag(for: photo.id)
            }
        }
    }

    private func assignTag(_ tagId: UUID, to photoID: UUID) {
        guard tagStore.tag(id: tagId) != nil,
              let idx = captured.firstIndex(where: { $0.id == photoID })
        else { return }
        captured[idx].tagId = tagId
    }

    private func clearTag(for photoID: UUID) {
        guard let idx = captured.firstIndex(where: { $0.id == photoID }) else { return }
        captured[idx].tagId = nil
    }

    // MARK: upload

    private var uploadBar: some View {
        VStack(spacing: 6) {
            if !captured.isEmpty && tagAssignedCount < captured.count {
                Text("\(captured.count - tagAssignedCount) photo(s) still need a tag")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if uploading { ProgressView().tint(.white) }
                    Text(uploading ? "Uploading…" : "Upload tagged (\(tagAssignedCount))")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    tagAssignedCount == 0 ? Theme.BG.secondary : Theme.CTP.mauve,
                    in: Capsule()
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(tagAssignedCount == 0 || uploading)
        }
        .padding(.bottom, 8)
    }

    // MARK: helpers

    private func loadPickerSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                await MainActor.run { captured.append(CapturedPhoto(image: img)) }
            }
        }
        await MainActor.run { autoAssignTags() }
        pickerItems = []
    }

    /// Pre-fills untagged captured photos with tags in sort order when auto-tag is
    /// enabled. No-op when disabled. Preserves any manual assignment and never
    /// reuses a tag, delegating the ordering rule to `AutoTagAssignment`.
    /// Outputs: nothing; mutates `captured[*].tagId` in place.
    private func autoAssignTags() {
        guard autoTagEnabled else { return }
        let assigned = AutoTagAssignment.assign(
            current: captured.map { $0.tagId },
            orderedTags: tagStore.tags.map { $0.id }
        )
        for (i, tagId) in assigned.enumerated() where captured[i].tagId != tagId {
            captured[i].tagId = tagId
        }
    }

    private func createTag() async {
        let trimmed = newTagDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if await tagStore.create(name: trimmed) != nil {
            newTagDraft = ""
            showNewTagField = false
        }
    }

    /// Encodes each tagged photo as JPEG and hands them to the store one by
    /// one. Untagged photos remain in the tray so the user can tag and resubmit.
    private func submit() async {
        uploading = true
        defer { uploading = false }
        var uploaded: Set<UUID> = []
        for photo in captured {
            // Same guard as `tagAssignedCount`: never POST a tagId that isn't
            // currently known to the tag store.
            guard let tagId = photo.tagId,
                  tagStore.tag(id: tagId) != nil,
                  let jpeg = photo.image.jpegData(compressionQuality: 0.85) else { continue }
            await store.upload(date: date, tagId: tagId, imageData: jpeg)
            uploaded.insert(photo.id)
        }
        captured.removeAll { uploaded.contains($0.id) }
        if captured.isEmpty {
            dismiss()
        }
    }
}
