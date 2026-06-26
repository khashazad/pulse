import SwiftUI

/// Drill-down screen for one calendar week: shows each day's workouts as
/// tappable `WorkoutRow`s under a day-header, navigating to `WorkoutDetailView`.
/// Navigation title is "Week of <weekStart>", derived from the loaded detail
/// while loading falls back to the `anchor` date.
/// Auth is resolved from the SwiftUI environment.
struct WeekTrendsView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: WeekTrendsModel?

    private let anchor: Date
    private let onOpenWorkout: (UUID) -> Void

    /// Initializes the view for a specific calendar week.
    /// - Parameters:
    ///   - anchor: A date inside the target calendar week.
    ///   - onOpenWorkout: Called with the workout UUID when the user taps a row.
    init(anchor: Date, onOpenWorkout: @escaping (UUID) -> Void) {
        self.anchor = anchor
        self.onOpenWorkout = onOpenWorkout
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = WeekTrendsModel(auth: auth, anchor: anchor) }
            if let m = model, case .idle = m.state { await m.load() }
        }
    }

    /// Navigation title derived from the loaded week's start date, or the anchor
    /// while data is still loading.
    /// - Returns: "Week of <abbreviated month> <day>" string.
    private var navigationTitle: String {
        if case let .loaded(detail) = model?.state {
            return "Week of \(detail.weekStart.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "Week of \(anchor.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Renders a loading spinner, error view, empty-week placeholder, or the day-grouped
    /// workout list.
    /// - Returns: The view for the current load state.
    @ViewBuilder private var content: some View {
        switch model?.state {
        case .none, .some(.idle), .some(.loading):
            ProgressView()
                .tint(Theme.FG.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case let .some(.failed(error)):
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load week",
                description: error.userMessage
            )
        case let .some(.loaded(detail)):
            if detail.dayGroups.isEmpty {
                EmptyStateView(
                    icon: "figure.run",
                    title: "No workouts",
                    description: "No workouts recorded for this week."
                )
            } else {
                weekContent(detail)
            }
        }
    }

    /// Scrollable list of day groups: each group renders a day header followed
    /// by tappable `WorkoutRow`s for that day's workouts.
    /// - Parameter detail: The loaded `WeekDetail` to render.
    /// - Returns: A `ScrollView` of labelled workout rows.
    private func weekContent(_ detail: WeekDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(detail.dayGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            group.date.formatted(
                                .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                            )
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)
                        ForEach(group.workouts) { workout in
                            Button {
                                onOpenWorkout(workout.id)
                            } label: {
                                WorkoutRow(workout: workout)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
    }
}
