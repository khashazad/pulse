/// Intake → Year sub-tab.
/// Renders the current year's daily logs as monthly buckets via
/// `PeriodIntakeModel(range: .year)`, plus an `AverageMacrosTable` summary.
import SwiftUI

/// Year-period summary screen: monthly kcal bars + average macros table.
struct YearView: View {
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
        .navigationTitle("This year")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = PeriodIntakeModel(range: .year, auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    /// Body for the loaded state. Computes monthly buckets and yearly averages from
    /// `logs` then assembles the summary card + macros table.
    /// Inputs:
    ///   - logs: daily logs for the current year.
    /// Outputs: composed scrollable view.
    private func loadedBody(_ logs: [DailyLog]) -> some View {
        let chronological = logs.sorted { $0.date < $1.date }
        let buckets = PeriodIntakeModel.monthlyBuckets(chronological)
        let avgKcal = chronological.avgCalories
        let dailyTarget = model?.targets?.calories

        return ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                PeriodSummaryCard(
                    title: "Year avg / day",
                    avgKcal: avgKcal,
                    buckets: buckets,
                    barsHeader: "Monthly avg",
                    dailyTarget: dailyTarget
                )
                .padding(.horizontal, 16)

                AverageMacrosTable(
                    avgKcal: avgKcal,
                    avgProteinG: Int(chronological.avgProtein.rounded()),
                    avgCarbsG: Int(chronological.avgCarbs.rounded()),
                    avgFatG: Int(chronological.avgFat.rounded())
                )
                .padding(.horizontal, 16)

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }
}
