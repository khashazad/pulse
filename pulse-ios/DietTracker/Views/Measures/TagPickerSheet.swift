/// Tag picker presented before capturing or selecting a progress photo.
///
/// Hosts `TagPickerSheet`, which lists the user's `ProgressPhotoTag`s from
/// `ProgressPhotoTagStore`, lets the user create a new tag inline (requires
/// network), and calls back with the chosen tag id. The caller then opens
/// the camera/library and uploads with that tag attached.
import SwiftUI

/// Modal sheet: pick a tag (or create one) for a new progress photo.
struct TagPickerSheet: View {
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss
    var onSelect: (ProgressPhotoTag) -> Void

    @State private var newName: String = ""
    @State private var creating = false
    @State private var createError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(spacing: 16) {
                    createRow
                    if let createError {
                        Text(createError)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.CTP.red)
                    }
                    list
                }
                .padding(16)
            }
            .navigationTitle("Pick a tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await tagStore.reload() }
        }
    }

    private var createRow: some View {
        HStack(spacing: 8) {
            TextField("New tag…", text: $newName)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { Task { await submitNew() } }
            Button {
                Task { await submitNew() }
            } label: {
                if creating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            .foregroundStyle(Theme.CTP.mauve)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(tagStore.tags) { tag in
                    Button {
                        onSelect(tag)
                        dismiss()
                    } label: {
                        HStack {
                            Text(tag.name)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.FG.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.BG.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func submitNew() async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        creating = true
        createError = nil
        defer { creating = false }
        if let tag = await tagStore.create(name: trimmed) {
            newName = ""
            onSelect(tag)
            dismiss()
        } else {
            createError = tagStore.lastError ?? "Couldn't create tag"
        }
    }
}
