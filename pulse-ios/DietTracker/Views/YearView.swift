import SwiftUI

struct YearView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: YearModel?

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
                        action: { Task { await model?.loadCurrentYear() } },
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
            if model == nil { model = YearModel(auth: auth) }
            await model?.loadCurrentYear()
        }
        .refreshable { await model?.loadCurrentYear() }
    }

    private func loadedBody(_ logs: [DailyLog]) -> some View {
        let chronological = logs.sorted { $0.date < $1.date }
        let buckets = YearModel.monthlyBuckets(chronological)
        let avgKcal = WeekModel.avgCalories(chronological)
        let dailyTarget = model?.targets?.calories
        let pct: Int? = {
            guard let dailyTarget, dailyTarget > 0, avgKcal > 0 else { return nil }
            return Int((Double(avgKcal) / Double(dailyTarget) * 100).rounded())
        }()

        return ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                summaryCard(
                    avgKcal: avgKcal,
                    pct: pct,
                    buckets: buckets,
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

    private func summaryCard(
        avgKcal: Int,
        pct: Int?,
        buckets: [PeriodBucket],
        dailyTarget: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Year avg / day")
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

            BucketKcalBars(buckets: buckets, header: "Monthly avg", targetCalories: dailyTarget)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .ctpCard()
    }
}
