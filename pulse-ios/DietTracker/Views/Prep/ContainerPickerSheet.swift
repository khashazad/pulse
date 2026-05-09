import SwiftUI

struct ContainerPickerSheet: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    let onPick: (Container) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                content
            }
            .navigationTitle("Pick a container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if model == nil { model = ContainersListModel(auth: auth) }
            await model?.load()
        }
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
                title: "Couldn't load",
                description: e.userMessage,
                action: { Task { await model?.load() } },
                actionLabel: "Retry"
            )
        case .loaded(let list) where list.isEmpty:
            EmptyStateView(
                icon: "cube.box",
                title: "No containers yet",
                description: "Add a container first."
            )
        case .loaded(let list):
            List {
                Section {
                    ForEach(list) { c in
                        Button {
                            onPick(c)
                            dismiss()
                        } label: {
                            ContainerRow(container: c)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.BG.tertiary)
                        .listRowSeparatorTint(Theme.separator)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}
