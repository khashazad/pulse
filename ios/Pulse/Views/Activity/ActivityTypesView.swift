/// ActivityTypesView: management screen listing every imported activity type with
/// its workout count and a cardio classification toggle. Each toggle fires an
/// optimistic update via `ActivityTypesModel.toggleCardio`.
import SwiftUI

/// Screen that lists all imported activity types and lets the user flip each
/// one's cardio classification via a Toggle.
struct ActivityTypesView: View {
    @State private var model: ActivityTypesModel

    /// Initializes the view with the shared auth session, creating its own model.
    /// - Parameter auth: The app's authenticated session.
    init(auth: AuthSession) {
        _model = State(initialValue: ActivityTypesModel(auth: auth))
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle("Activity Types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await model.load() }
    }

    /// Switches on `model.state` to render a loading spinner, an error placeholder,
    /// an empty placeholder, or the full types list.
    /// - Returns: The view matching the current load state.
    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .tint(Theme.FG.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load activity types",
                description: error.userMessage,
                action: { Task { await model.load() } },
                actionLabel: "Retry"
            )
        case .loaded(let types) where types.isEmpty:
            EmptyStateView(
                icon: "tag",
                title: "No activity types",
                description: "Activity types appear here once workouts are imported."
            )
        case .loaded(let types):
            typesList(types)
        }
    }

    /// A list of all activity types with name, count subtitle, and a cardio toggle.
    /// - Parameter types: The loaded activity type settings.
    /// - Returns: An inset-grouped list view with Theme styling.
    private func typesList(_ types: [ActivityTypeSetting]) -> some View {
        List {
            Section {
                ForEach(types) { setting in
                    typeRow(setting)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// A single row showing the activity type's display name, workout count, and a
    /// trailing cardio Toggle that fires an optimistic mutation on change.
    /// - Parameter setting: The activity type setting to display.
    /// - Returns: A styled list row view.
    private func typeRow(_ setting: ActivityTypeSetting) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.FG.primary)
                Text("\(setting.count) \(setting.count == 1 ? "workout" : "workouts")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            Spacer()
            Toggle(
                "Cardio",
                isOn: Binding(
                    get: { setting.isCardio },
                    set: { _ in Task { await model.toggleCardio(setting) } }
                )
            )
            .labelsHidden()
            .tint(Theme.CTP.mauve)
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.BG.tertiary)
        .listRowSeparatorTint(Theme.separator)
    }
}
