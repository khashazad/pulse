import SwiftUI

/// Detail screen for one workout: Apple stats header plus, when linked,
/// expandable per-exercise Hevy set detail.
struct WorkoutDetailView: View {
    let id: UUID
    @State private var model: WorkoutDetailModel

    /// - Parameters:
    ///   - id: The workout UUID to load and display.
    ///   - auth: The signed-in session used to build an authorized client.
    init(id: UUID, auth: AuthSession) {
        self.id = id
        _model = State(initialValue: WorkoutDetailModel(id: id, auth: auth))
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            switch model.state {
            case .idle, .loading:
                ProgressView().tint(Theme.FG.secondary)
            case let .failed(error):
                EmptyStateView(icon: "exclamationmark.triangle",
                               title: "Couldn't load workout",
                               description: error.userMessage)
            case let .loaded(detail):
                content(detail)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
    }

    private func content(_ d: ActivityWorkoutDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(d)
                statsGrid(d)
                if !d.exercises.isEmpty {
                    strengthSection(d)
                } else if d.activityType.localizedCaseInsensitiveContains("strength") {
                    Text("No set detail recorded for this workout.")
                        .font(.system(size: 13)).foregroundStyle(Theme.FG.tertiary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, Theme.Layout.dockClearance)
        }
    }

    private func header(_ d: ActivityWorkoutDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(ActivityType.color(d.activityType)).frame(width: 10, height: 10)
                Text(ActivityType.displayName(d.activityType))
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.FG.primary)
            }
            Text(d.startTime.formatted(date: .complete, time: .shortened))
                .font(.system(size: 13)).foregroundStyle(Theme.FG.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func statsGrid(_ d: ActivityWorkoutDetail) -> some View {
        let stats = WorkoutDetailModel.appleStats(d)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                         spacing: 10) {
            ForEach(stats, id: \.label) { stat in
                VStack(spacing: 4) {
                    Text(stat.value).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.FG.primary)
                    Text(stat.label).font(.system(size: 10, weight: .medium))
                        .tracking(0.4).textCase(.uppercase).foregroundStyle(Theme.FG.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12).ctpCard()
            }
        }
    }

    private func strengthSection(_ d: ActivityWorkoutDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = d.strengthTotals {
                HStack {
                    Text("STRENGTH").font(.system(size: 11, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(Theme.FG.secondary)
                    Spacer()
                    Text("\(t.setCount) sets · \(Int(t.volumeLbs.rounded())) lb")
                        .font(.system(size: 12)).foregroundStyle(Theme.FG.tertiary)
                }
            }
            ForEach(d.exercises) { ExerciseCard(exercise: $0) }
        }
        .padding(.top, 4)
    }
}
