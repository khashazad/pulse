/// Intake → Month sub-tab.
/// Renders the current month's daily logs as weekly buckets via `MonthModel`,
/// plus an `AverageMacrosTable` summary.
import SwiftUI

/// Month-period summary screen: weekly kcal bars + average macros table.
struct MonthView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: MonthModel?

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
                        action: { Task { await model?.loadCurrentMonth() } },
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
            if model == nil { model = MonthModel(auth: auth) }
            await model?.loadCurrentMonth()
        }
        .refreshable { await model?.loadCurrentMonth() }
    }

    /// Body for the loaded state. Computes weekly buckets and averages from `logs`
    /// and assembles the summary card + macros table.
    /// Inputs:
    ///   - logs: daily logs for the current month.
    /// Outputs: composed scrollable view.
    private func loadedBody(_ logs: [DailyLog]) -> some View {
        let chronological = logs.sorted { $0.date < $1.date }
        let buckets = MonthModel.weeklyBuckets(chronological)
        let avgKcal = WeekModel.avgCalories(chronological)
        let dailyTarget = model?.targets?.calories
        let pct: Int? = {
            guard let dailyTarget, dailyTarget > 0, avgKcal > 0 else { return nil }
            return Int((Double(avgKcal) / Double(dailyTarget) * 100).rounded())
        }()

        return ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                summaryCard(
                    title: "Month avg / day",
                    avgKcal: avgKcal,
                    pct: pct,
                    buckets: buckets,
                    barsHeader: "Weekly avg",
                    dailyTarget: dailyTarget
                )
                .padding(.horizontal, 16)

                AverageMacrosTable(
                    avgKcal: avgKcal,
                    avgProteinG: Int(WeekModel.avgProtein(chronological).rounded()),
                    avgCarbsG: Int(WeekModel.avgCarbs(chronological).rounded()),
                    avgFatG: Int(WeekModel.avgFat(chronological).rounded())
                )
                .padding(.horizontal, 16)

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }

    /// Top summary card with title, daily avg kcal, percent-of-target chip, and bucket bars.
    /// Inputs:
    ///   - title: card title text.
    ///   - avgKcal: average daily kcal over the period.
    ///   - pct: percent of daily kcal target reached on average (nil if no target).
    ///   - buckets: weekly buckets for the bar chart.
    ///   - barsHeader: caption for the bars sub-section.
    ///   - dailyTarget: daily kcal target used for the bar threshold line (nil if unset).
    /// Outputs: composed card view.
    private func summaryCard(
        title: String,
        avgKcal: Int,
        pct: Int?,
        buckets: [PeriodBucket],
        barsHeader: String,
        dailyTarget: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(avgKcal.formatted())
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.FG.primary)
                        Text("cal")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                }
                Spacer()
                if let pct {
                    Text("\(pct)% of target")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Theme.CTP.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.CTP.green.opacity(0.14)))
                }
            }

            BucketKcalBars(buckets: buckets, header: barsHeader, targetCalories: dailyTarget)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .ctpCard()
    }
}
