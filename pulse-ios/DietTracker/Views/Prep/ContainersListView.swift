import SwiftUI

struct ContainersListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    @State private var showAdd = false
    @State private var editing: Container?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Containers")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
                .sheet(isPresented: $showAdd) {
                    ContainerEditView(existing: nil) { _ in
                        Task { await model?.load() }
                    }
                    .environment(settings)
                }
                .sheet(item: $editing) { container in
                    ContainerEditView(existing: container) { _ in
                        Task { await model?.load() }
                    }
                    .environment(settings)
                }
        }
        .task { await ensureModel(); await model?.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .idle {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let e):
            ContentUnavailableView {
                Label("Couldn't load containers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e.userMessage)
            } actions: {
                Button("Retry") { Task { await model?.load() } }
            }
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView {
                Label("No containers yet", systemImage: "cube.box")
            } description: {
                Text("Add your first pot or meal-prep box.")
            } actions: {
                Button("Add a container") { showAdd = true }
            }
        case .loaded(let list):
            List {
                ForEach(list) { c in
                    Button {
                        editing = c
                    } label: {
                        ContainerRow(container: c)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in
                    Task {
                        for i in idx { await model?.delete(id: list[i].id) }
                    }
                }
            }
        }
    }

    private func ensureModel() async {
        if model == nil { model = ContainersListModel(settings: settings) }
    }
}

struct ContainerRow: View {
    @Environment(AppSettings.self) private var settings
    let container: Container

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(container.name).font(.body)
                Text("\(Int(container.tareWeightG.rounded())) g")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if container.hasPhoto, let client = settings.makeClient() {
            AuthorizedAsyncImage(
                request: client.containerPhotoRequest(id: container.id, size: .thumb),
                content: { $0.resizable().scaledToFill() },
                placeholder: { Color.gray.opacity(0.2) }
            )
        } else {
            ZStack {
                Color.gray.opacity(0.15)
                Image(systemName: "cube.box").foregroundStyle(.secondary)
            }
        }
    }
}
