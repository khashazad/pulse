/// WeightTrendsModel: view-model for the weight-trends screen.
/// Loads weight entries and daily calories over a selected range, refreshes
/// user targets, and computes derived analytics via WeightAnalytics.
/// Also defines TrendsRange, the user-selectable window enum.
/// Role: backing model for the Trends view and its chart/headline metrics.
import Foundation
import Observation

/// User-selectable range for the weight-trends screen.
enum TrendsRange: String, CaseIterable, Hashable {
    case d30, d90, y1, all

    var days: Int {
        switch self {
        case .d30: return 30
        case .d90: return 90
        case .y1:  return 365
        case .all: return 365 // hard cap; server allows max 366
        }
    }
}

/// Observable view-model that orchestrates weight + calorie loading and runs WeightAnalytics for the trends screen.
@Observable
final class WeightTrendsModel {
    private(set) var entries: [WeightEntry] = []
    private(set) var kcal: [CaloriesDailyRow] = []
    private(set) var analytics: LoadState<WeightAnalyticsResult> = .idle
    var range: TrendsRange = .y1

    private weak var auth: AuthSession?
    private weak var targetsStore: UserTargetsStore?

    var targetWeightLb: Double? { targetsStore?.targets?.targetWeightLb }

    /// Initializes the trends model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    ///   - targetsStore: shared store providing the user's target weight.
    init(auth: AuthSession, targetsStore: UserTargetsStore) {
        self.auth = auth
        self.targetsStore = targetsStore
    }

    /// Loads weight entries and daily calories for the selected `range`, refreshes
    /// targets, then computes analytics. Routes 401 through AuthSession.
    /// Inputs:
    ///   - today: anchor date for the trailing window (defaults to now).
    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            analytics = .failed(.notSignedIn)
            return
        }
        analytics = .loading
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today

        async let entriesTask = client.listWeightEntries(from: from, to: today)
        async let kcalTask = client.fetchCaloriesDaily(from: from, to: today)

        do {
            self.entries = try await entriesTask
            self.kcal = try await kcalTask
            await targetsStore?.refresh(client: client)
            let result = WeightAnalytics.compute(
                entries: entries,
                kcal: kcal,
                targetWeightLb: targetWeightLb,
                today: today
            )
            analytics = .loaded(result)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            analytics = .failed(error)
        } catch {
            analytics = .failed(.server(status: -1))
        }
    }

    /// Recomputes analytics from already-loaded entries/kcal without re-hitting the network.
    /// Used when the user changes the target weight inline.
    /// Inputs:
    ///   - today: anchor date for the computation (defaults to now).
    func recomputeAnalytics(today: Date = Date()) {
        let result = WeightAnalytics.compute(
            entries: entries,
            kcal: kcal,
            targetWeightLb: targetWeightLb,
            today: today
        )
        analytics = .loaded(result)
    }
}
