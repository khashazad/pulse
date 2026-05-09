import SwiftUI

struct MealsView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: MealsModel?
    let onOpen: (MealSummary) -> Void

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView()
                        .tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let meals):
                    if meals.isEmpty {
                        EmptyStateView(
                            icon: "fork.knife",
                            title: "No meals saved",
                            description: "Meals you save on the server will appear here."
                        )
                    } else {
                        loadedBody(meals)
                    }
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
        .navigationTitle("Meals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            if model == nil { model = MealsModel(auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }

    private func loadedBody(_ meals: [MealSummary]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Saved recipes")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)
                    Spacer()
                    Text("\(meals.count) saved")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.FG.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(meals.enumerated()), id: \.element.id) { idx, meal in
                        Button { onOpen(meal) } label: {
                            MealRow(summary: meal)
                        }
                        .buttonStyle(.plain)
                        if idx < meals.count - 1 {
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .ctpCard()
                .padding(.horizontal, 16)

                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.top, 4)
        }
    }
}
