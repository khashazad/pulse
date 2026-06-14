/// Intake → Month sub-tab.
/// Renders the current month's daily logs as weekly buckets via
/// `PeriodIntakeModel(range: .month)`, plus an `AverageMacrosTable` summary.
import SwiftUI

/// Month-period summary screen: weekly kcal bars + average macros table.
struct MonthView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: PeriodIntakeModel?

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                        .tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let list):
                    loadedBody(list.logs)
                case .failed(let error):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: error.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .navigationTitle("This month")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = PeriodIntakeModel(range: .month, auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    /// Body for the loaded state. Groups `logs` into weeks and renders a stacked-macro
    /// bar row per week (shared y-scale), preceded by a macro color key and followed by
    /// the month-average macros table.
    /// Inputs:
    ///   - logs: daily logs for the current month.
    /// Outputs: composed scrollable view.
    private func loadedBody(_ logs: [DailyLog]) -> some View {
        // `weeklyLogGroups` sorts each week's days internally, and avg/ceiling are
        // order-independent, so no pre-sort of `logs` is needed here.
        let weeks = PeriodIntakeModel.weeklyLogGroups(logs)
        let avgKcal = logs.avgCalories
        let dailyTarget = model?.targets?.calories
        // Shared vertical scale across all week rows so bars and the target line line up.
        let ceiling = logs.calorieCeiling(target: dailyTarget)

        return ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                if weeks.isEmpty {
                    EmptyStateView(
                        icon: "calendar",
                        title: "No intake yet",
                        description: "Days you log this month will show up here as weekly macro bars."
                    )
                    .padding(.top, 40)
                } else {
                    MacroLegend()
                        .padding(.horizontal, 16)

                    ForEach(weeks) { week in
                        WeeklyMacroBars(group: week, ceiling: ceiling, targetCalories: dailyTarget)
                            .padding(.horizontal, 16)
                    }

                    AverageMacrosTable(
                        avgKcal: avgKcal,
                        avgProteinG: Int(logs.avgProtein.rounded()),
                        avgCarbsG: Int(logs.avgCarbs.rounded()),
                        avgFatG: Int(logs.avgFat.rounded())
                    )
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }
}
