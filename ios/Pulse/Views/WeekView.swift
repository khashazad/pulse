/// Intake → Week sub-tab.
/// Renders the last seven days of intake via `PeriodIntakeModel(range: .week)`:
/// daily kcal bars, week total + percent-of-target chip, and average macros table.
import SwiftUI

/// Week-period summary screen: daily kcal bars + week total + average macros table.
struct WeekView: View {
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
        .navigationTitle("This week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = PeriodIntakeModel(range: .week, auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    /// Body for the loaded state. Assembles the daily-bars card (tap a day for its
    /// macros) and the week-average macros table. The week-total kcal number is
    /// intentionally omitted — the per-day bars and averages carry the signal.
    /// Inputs:
    ///   - logs: daily logs for the last seven days.
    /// Outputs: composed scrollable view.
    private func loadedBody(_ logs: [DailyLog]) -> some View {
        let chronological = logs.sorted { $0.date < $1.date }
        let dailyTarget = model?.targets?.calories
        return ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                weekSummaryCard(logs: chronological, dailyTarget: dailyTarget)
                    .padding(.horizontal, 16)

                AverageMacrosTable(
                    avgKcal: chronological.avgCalories,
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

    /// Daily-bars card: the seven-day kcal bar chart with tap-to-reveal day detail.
    /// The week-total number and percent-of-target chip were removed by design;
    /// the bars and the averages table below carry the week's signal.
    /// Inputs:
    ///   - logs: chronologically sorted daily logs.
    ///   - dailyTarget: daily kcal target used for the bar threshold line.
    /// Outputs: composed card view.
    private func weekSummaryCard(logs: [DailyLog], dailyTarget: Int?) -> some View {
        DailyKcalBars(logs: logs, targetCalories: dailyTarget)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .ctpCard()
    }
}
