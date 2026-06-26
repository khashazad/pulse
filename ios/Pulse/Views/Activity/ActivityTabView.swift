import SwiftUI

/// Activity feed root: a tap-through week summary strip, type filter chips,
/// and a chronological feed grouped by week with infinite scroll.
struct ActivityTabView: View {
    let auth: AuthSession
    let onOpenWorkout: (UUID) -> Void
    let onOpenTrends: () -> Void
    @State private var model: ActivityFeedModel

    /// Initializes the view with the shared auth session and navigation callbacks.
    /// - Parameters:
    ///   - auth: The app's authenticated session.
    ///   - onOpenWorkout: Called with the workout's UUID when the user taps a row.
    ///   - onOpenTrends: Called when the user taps the summary strip to open trends.
    init(auth: AuthSession, onOpenWorkout: @escaping (UUID) -> Void,
         onOpenTrends: @escaping () -> Void) {
        self.auth = auth
        self.onOpenWorkout = onOpenWorkout
        self.onOpenTrends = onOpenTrends
        _model = State(initialValue: ActivityFeedModel(auth: auth))
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            content
        }
        .navigationTitle("Activity")
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

    /// The scrollable workout feed with summary strip, filter chips, and week-grouped rows.
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

    /// Tappable strip showing this week's duration, session count, and calories.
    /// - Parameter s: The current week's activity summary.
    /// - Returns: A card-styled button that fires `onOpenTrends`.
    private func summaryStrip(_ s: ActivitySummary) -> some View {
        Button { onOpenTrends() } label: {
            HStack(spacing: 18) {
                metric(s.totals.totalDurationMin.asDurationFromMinutes, "this week")
                metric("\(s.totals.workoutCount)", "sessions")
                metric("\(Int(s.totals.totalActiveEnergyCal.rounded()))", "kcal")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .padding(16).ctpCard()
        }
        .buttonStyle(.plain)
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

    /// Two filter rows: parent groups (All / Weights / Cardio), then the selected
    /// group's subtypes when a group is active.
    /// - Returns: A vertical stack of one or two horizontally-scrolling chip rows.
    private var filterChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", active: model.groupFilter == nil) { Task { await model.setGroup(nil) } }
                    ForEach(ActivityGroup.allCases) { group in
                        chip(group.displayName, active: model.groupFilter == group) {
                            Task { await model.setGroup(group) }
                        }
                    }
                }
            }
            if let group = model.groupFilter {
                let subtypes = model.availableSubtypes(in: group)
                // Only worth a drill-in row when the group has more than one
                // subtype — e.g. Weights (one strength type) shows no second row.
                if subtypes.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All \(group.displayName)", active: model.subtypeFilter == nil) {
                                Task { await model.setSubtype(nil) }
                            }
                            ForEach(subtypes, id: \.self) { type in
                                chip(ActivityType.displayName(type), active: model.subtypeFilter == type) {
                                    Task { await model.setSubtype(type) }
                                }
                            }
                        }
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
