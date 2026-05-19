/// Capture flow for adding progress photos with drag-and-drop tag assignment.
///
/// Hosts `PhotoCaptureSession`, which collects photos from the camera and/or
/// photo library into a 2-up grid, shows the user's tags as a horizontally-
/// scrolling row of draggable chips at the top, and lets the user drop a
/// chip onto a photo to assign that tag. Upload submits every tagged photo
/// via `ProgressPhotoStore.upload(date:tagId:imageData:)` — untagged photos
/// are skipped (and the button is disabled until at least one is tagged).
import PhotosUI
import SwiftUI
import UIKit

struct PhotoCaptureSession: View {
    @Environment(ProgressPhotoStore.self) private var store
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss
    let date: Date

    /// Identity-stable wrapper around a captured `UIImage` plus its
    /// (currently assigned, if any) tag.
    private struct CapturedPhoto: Identifiable, Hashable {
        let id = UUID()
        let image: UIImage
        var tagId: UUID?
        static func == (lhs: CapturedPhoto, rhs: CapturedPhoto) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @State private var captured: [CapturedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var uploading = false
    @State private var newTagDraft: String = ""
    @State private var showNewTagField = false

    private var tagAssignedCount: Int {
        captured.lazy.filter { $0.tagId != nil }.count
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
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                Task { await loadPickerSelection(items) }
            }
            .task { await tagStore.reload() }
        }
    }

    // MARK: tag bar

    /// Floating row of draggable tag chips plus an inline "new tag" affordance.
    /// Each chip is `.draggable` with its UUID string payload; photo cells
    /// below are `.dropDestination(for: String.self)` and parse the UUID back
    /// out to update their `tagId`.
    private var tagBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Drag a tag onto a photo")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                Button {
                    withAnimation { showNewTagField.toggle() }
                } label: {
                    Image(systemName: showNewTagField ? "minus.circle" : "plus.circle")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            if showNewTagField {
                newTagRow
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tagStore.tags) { tag in
                        chipView(tag: tag)
                            .draggable(tag.id.uuidString) {
                                chipView(tag: tag)
                                    .opacity(0.85)
                            }
                    }
                }
                .padding(.vertical, 2)
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

    private func chipView(tag: ProgressPhotoTag) -> some View {
        Text(tag.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.FG.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.CTP.mauve.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.CTP.mauve, lineWidth: 1))
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
    /// assigned tag chip or a "drop a tag" placeholder, and a remove button.
    /// The whole cell is a drop destination for tag UUID strings.
    private func photoCell(_ photo: CapturedPhoto) -> some View {
        let assignedTag = photo.tagId.flatMap { tagStore.tag(id: $0) }
        return Image(uiImage: photo.image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0/5.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                Group {
                    if let tag = assignedTag {
                        Text(tag.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.CTP.mauve, in: Capsule())
                    } else {
                        Text("Drop a tag")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
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
            .overlay(alignment: .bottomTrailing) {
                if assignedTag != nil {
                    Button {
                        if let idx = captured.firstIndex(where: { $0.id == photo.id }) {
                            captured[idx].tagId = nil
                        }
                    } label: {
                        Image(systemName: "tag.slash.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        assignedTag == nil ? Theme.FG.tertiary.opacity(0.4) : .clear,
                        style: StrokeStyle(lineWidth: 1, dash: assignedTag == nil ? [4] : [])
                    )
            )
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let uuid = UUID(uuidString: raw) else { return false }
                if let idx = captured.firstIndex(where: { $0.id == photo.id }) {
                    captured[idx].tagId = uuid
                    return true
                }
                return false
            }
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
        pickerItems = []
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
            guard let tagId = photo.tagId,
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
