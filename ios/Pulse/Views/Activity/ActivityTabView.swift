import SwiftUI

/// All-activities feed: a non-tappable week summary strip, a single activity-type
/// filter chip row, and a chronological feed grouped by week with infinite scroll.
/// This view is pushed from `ActivityTrendsView`; Trends is the Activity tab root.
struct ActivityTabView: View {
    let auth: AuthSession
    let onOpenWorkout: (UUID) -> Void
    @State private var model: ActivityFeedModel

    /// Initializes the view with the shared auth session and a workout-open callback.
    /// - Parameters:
    ///   - auth: The app's authenticated session.
    ///   - onOpenWorkout: Called with the workout's UUID when the user taps a row.
    init(auth: AuthSession, onOpenWorkout: @escaping (UUID) -> Void) {
        self.auth = auth
        self.onOpenWorkout = onOpenWorkout
        _model = State(initialValue: ActivityFeedModel(auth: auth))
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle("All Activities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { if case .idle = model.state { await model.loadFirst() } }
    }

    /// The primary content switcher: spinner, error placeholder, empty placeholder, or feed.
    /// - Returns: A view matching the current load state.
    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().tint(Theme.FG.secondary)
        case let .failed(error):
            EmptyStateView(icon: "exclamationmark.triangle",
                           title: "Couldn't load activity",
                           description: error.userMessage)
        case let .loaded(loaded):
            if loaded.isEmpty {
                EmptyStateView(icon: "figure.run",
                               title: "No workouts yet",
                               description: "Imported workouts will appear here.")
            } else {
                feed
            }
        }
    }

    /// The scrollable workout feed with summary strip, type filter chips, and week-grouped rows.
    /// - Returns: A `ScrollView` containing the full feed layout.
    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                if let s = model.summary { summaryStrip(s) }
                filterChips
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.workouts) { w in
                            Button { onOpenWorkout(w.id) } label: { WorkoutRow(workout: w) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        weekHeader(section.weekStart)
                    }
                }
                if model.canLoadMore {
                    ProgressView().tint(Theme.FG.tertiary).padding(.vertical, 12)
                        .task { await model.loadMore() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
    }

    /// Non-tappable strip showing this week's duration, session count, and calories.
    /// - Parameter s: The current week's activity summary.
    /// - Returns: A card-styled info strip.
    private func summaryStrip(_ s: ActivitySummary) -> some View {
        HStack(spacing: 18) {
            metric(s.totals.totalDurationMin.asDurationFromMinutes, "this week")
            metric("\(s.totals.workoutCount)", "sessions")
            metric("\(Int(s.totals.totalActiveEnergyCal.rounded()))", "kcal")
            Spacer()
        }
        .padding(16).ctpCard()
    }

    /// A single headline metric column for the summary strip.
    /// - Parameters:
    ///   - value: The formatted numeric or duration string.
    ///   - label: The uppercased secondary label beneath the value.
    /// - Returns: A vertically stacked metric view.
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.FG.primary)
            Text(label).font(.system(size: 10, weight: .medium)).tracking(0.3)
                .textCase(.uppercase).foregroundStyle(Theme.FG.tertiary)
        }
    }

    /// A single chip row: "All" followed by one chip per known activity type.
    /// Tapping a chip reloads the feed filtered to that type.
    /// - Returns: A horizontally scrolling row of pill-shaped filter buttons.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", active: model.typeFilter == nil) { Task { await model.setType(nil) } }
                ForEach(model.availableTypes, id: \.self) { type in
                    chip(ActivityType.displayName(type), active: model.typeFilter == type) {
                        Task { await model.setType(type) }
                    }
                }
            }
        }
    }

    /// A single filter chip button.
    /// - Parameters:
    ///   - label: The chip's display text.
    ///   - active: Whether this chip represents the current filter.
    ///   - tap: Action to perform when the chip is tapped.
    /// - Returns: A pill-shaped toggle button styled via Theme tokens.
    private func chip(_ label: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(.system(size: 13, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.CTP.base : Theme.FG.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Layout.chipRadius)
                    .fill(active ? Theme.tint : Theme.BG.tertiary))
        }
        .buttonStyle(.plain)
    }

    /// Sticky section header showing the formatted week start.
    /// - Parameter start: The Monday that opens the week section.
    /// - Returns: A full-width text header pinned while scrolling.
    private func weekHeader(_ start: Date) -> some View {
        Text(Self.weekLabel(start))
            .font(.system(size: 12, weight: .semibold)).tracking(0.5)
            .foregroundStyle(Theme.FG.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.top, 4)
            .background(Theme.BG.primary)
    }

    /// Formats a week-start date as a header label, e.g. "Week of Jun 22".
    /// - Parameter start: The Monday that starts the week.
    /// - Returns: A short header string.
    static func weekLabel(_ start: Date) -> String {
        "Week of " + start.formatted(.dateTime.month(.abbreviated).day())
    }
}
