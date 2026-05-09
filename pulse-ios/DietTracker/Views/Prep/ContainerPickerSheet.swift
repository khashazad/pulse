import SwiftUI

struct ContainerPickerSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainersListModel?
    let onPick: (Container) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                case .failed(let e):
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(e.userMessage)
                    )
                case .loaded(let list) where list.isEmpty:
                    ContentUnavailableView(
                        "No containers yet",
                        systemImage: "cube.box",
                        description: Text("Add a container first.")
                    )
                case .loaded(let list):
                    List(list) { c in
                        Button {
                            onPick(c)
                            dismiss()
                        } label: {
                            ContainerRow(container: c)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pick a container")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            if model == nil { model = ContainersListModel(settings: settings) }
            await model?.load()
        }
    }
}
