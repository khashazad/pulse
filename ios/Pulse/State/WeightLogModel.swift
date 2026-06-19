/// WeightLogModel: view-model for the weight-logging screen.
/// Loads the trailing 90 days of weight entries, exposes today's entry, and
/// performs upsert/delete with optimistic local state mutation.
/// Role: backing model for the daily weight entry UI.
import Foundation
import Observation

/// Observable view-model that loads and mutates the user's weight entries for the last ~90 days.
@Observable
final class WeightLogModel {
    private(set) var state: LoadState<[WeightEntry]> = .idle
    private weak var auth: AuthSession?

    /// Number of trailing days the weight log loads — and the floor for how far
    /// back a missed weigh-in can be backfilled. Single source of truth shared by
    /// `load` and the backfill UI so the load window and backfill floor can't drift.
    static let windowDays = 89

    /// Computes the earliest day in the trailing load/backfill window.
    /// - Parameter today: The anchor date the window is measured back from.
    /// - Returns: `today` minus `windowDays` days (falls back to `today` if date
    ///   arithmetic fails).
    static func windowStart(from today: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -windowDays, to: today) ?? today
    }

    /// Initializes the weight-log model.
    /// Inputs:
    ///   - auth: auth session used to construct an authenticated client.
    init(auth: AuthSession) {
        self.auth = auth
    }

    /// The currently loaded entries, or an empty array if not yet loaded.
    var entries: [WeightEntry] {
        if case let .loaded(entries) = state { return entries }
        return []
    }

    /// Resolves the loaded entry for a given calendar day, if any.
    /// - Parameter day: The day to look up, compared at start-of-day.
    /// - Returns: The matching `WeightEntry`, or `nil` if none exists.
    func entry(on day: Date) -> WeightEntry? {
        let target = Calendar.current.startOfDay(for: day)
        return entries.first { Calendar.current.startOfDay(for: $0.date) == target }
    }

    var todayEntry: WeightEntry? { entry(on: Date()) }

    /// Fetches the last 90 days of weight entries; sorts descending; routes 401 through AuthSession.
    /// Inputs:
    ///   - today: anchor date for the trailing-90-day window (defaults to now).
    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        let from = Self.windowStart(from: today)
        do {
            let entries = try await client.listWeightEntries(from: from, to: today)
            state = .loaded(entries.sorted { $0.date > $1.date })
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Creates or replaces the weight entry for a given date and updates local state in place.
    /// Inputs:
    ///   - date: calendar day for the entry.
    ///   - weight: numeric weight in `unit`.
    ///   - unit: lb or kg, used by the server for storage.
    func upsert(date: Date, weight: Double, unit: WeightUnit) async {
        guard let client = auth?.makeClient() else { return }
        do {
            let updated = try await client.upsertWeight(date: date, weight: weight, unit: unit)
            if case var .loaded(entries) = state {
                entries.removeAll {
                    Calendar.current.startOfDay(for: $0.date) ==
                    Calendar.current.startOfDay(for: updated.date)
                }
                entries.append(updated)
                entries.sort { $0.date > $1.date }
                state = .loaded(entries)
            } else {
                state = .loaded([updated])
            }
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Deletes the weight entry for a given date and removes it from local state.
    /// Inputs:
    ///   - date: calendar day to delete.
    func delete(date: Date) async {
        guard let client = auth?.makeClient() else { return }
        do {
            try await client.deleteWeight(date: date)
            if case var .loaded(entries) = state {
                entries.removeAll {
                    Calendar.current.startOfDay(for: $0.date) ==
                    Calendar.current.startOfDay(for: date)
                }
                state = .loaded(entries)
            }
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
