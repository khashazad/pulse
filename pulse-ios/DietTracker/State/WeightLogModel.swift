import Foundation
import Observation

@Observable
final class WeightLogModel {
    private(set) var state: LoadState<[WeightEntry]> = .idle
    private weak var auth: AuthSession?

    init(auth: AuthSession) {
        self.auth = auth
    }

    var todayEntry: WeightEntry? {
        guard case let .loaded(entries) = state else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return entries.first { Calendar.current.startOfDay(for: $0.date) == today }
    }

    func load(today: Date = Date()) async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -89, to: today) ?? today
        do {
            let entries = try await client.listWeightEntries(from: from, to: today)
            state = .loaded(entries.sorted { $0.date > $1.date })
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

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
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

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
        } catch let error as DietTrackerError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }
}
