/// Manage-tags screen for progress photos.
///
/// Hosts `ManageTagsView`, which lists every `ProgressPhotoTag` from
/// `ProgressPhotoTagStore` with an inline rename affordance, plus a "New tag"
/// row at the top. Tag deletion is intentionally not exposed in this release.
import SwiftUI

struct ManageTagsView: View {
    @Environment(ProgressPhotoTagStore.self) private var tagStore
    @State private var newName: String = ""
    @State private var creating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    createRow
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.CTP.red)
                    }
                    list
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
                .padding(16)
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .task { await tagStore.reload() }
    }

    private var createRow: some View {
        HStack(spacing: 8) {
            TextField("New tag…", text: $newName)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { Task { await submit() } }
            Button {
                Task { await submit() }
            } label: {
                if creating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
        }
    }

    private var list: some View {
        VStack(spacing: 6) {
            ForEach(tagStore.tags) { tag in
                TagRow(tag: tag, onRename: { newName in
                    Task {
                        if await tagStore.rename(id: tag.id, name: newName) == nil {
                            errorMessage = tagStore.lastError
                        } else {
                            errorMessage = nil
                        }
                    }
                })
            }
        }
    }

    private func submit() async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        creating = true
        defer { creating = false }
        if await tagStore.create(name: trimmed) == nil {
            errorMessage = tagStore.lastError
        } else {
            errorMessage = nil
            newName = ""
        }
    }
}

private struct TagRow: View {
    let tag: ProgressPhotoTag
    var onRename: (String) -> Void

    @State private var draft: String = ""
    @State private var editing: Bool = false

    var body: some View {
        HStack {
            if editing {
                TextField("Tag name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit {
                        let trimmed = draft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != tag.name {
                            onRename(trimmed)
                        }
                        editing = false
                    }
                Button("Cancel") { editing = false; draft = tag.name }
                    .foregroundStyle(Theme.FG.tertiary)
            } else {
                Text(tag.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                Spacer()
                Button {
                    draft = tag.name
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.BG.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
