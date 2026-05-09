import SwiftUI

struct ContainersListView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    @State private var showAdd = false
    @State private var editing: Container?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                content
            }
            .navigationTitle("Containers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                ContainerEditView(existing: nil) { _ in
                    Task { await model?.load() }
                }
                .environment(auth)
            }
            .sheet(item: $editing) { container in
                ContainerEditView(existing: container) { _ in
                    Task { await model?.load() }
                }
                .environment(auth)
            }
        }
        .preferredColorScheme(.dark)
        .task { await ensureModel(); await model?.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle, .loading:
            ProgressView()
                .tint(Theme.CTP.mauve)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let e):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load containers",
                description: e.userMessage,
                action: { Task { await model?.load() } },
                actionLabel: "Retry"
            )
        case .loaded(let list) where list.isEmpty:
            EmptyStateView(
                icon: "cube.box",
                title: "No containers yet",
                description: "Add your first pot or meal-prep box.",
                action: { showAdd = true },
                actionLabel: "Add a container"
            )
        case .loaded(let list):
            List {
                Section {
                    ForEach(list) { c in
                        Button {
                            editing = c
                        } label: {
                            ContainerRow(container: c)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.BG.tertiary)
                        .listRowSeparatorTint(Theme.separator)
                    }
                    .onDelete { idx in
                        Task {
                            for i in idx { await model?.delete(id: list[i].id) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func ensureModel() async {
        if model == nil { model = ContainersListModel(auth: auth) }
    }
}

struct ContainerRow: View {
    @Environment(AuthSession.self) private var auth
    let container: Container

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                Text("\(Int(container.tareWeightG.rounded())) g")
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if container.hasPhoto, let client = auth.makeClient() {
            AuthorizedAsyncImage(
                request: client.containerPhotoRequest(id: container.id, size: .thumb),
                content: { $0.resizable().scaledToFill() },
                placeholder: { Theme.CTP.surface0 }
            )
        } else {
            ZStack {
                Theme.CTP.surface0
                Image(systemName: "cube.box")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }
}
