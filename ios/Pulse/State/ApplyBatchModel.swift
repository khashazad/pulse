// Pulse/State/ApplyBatchModel.swift
/// Backing model for the "apply prep portions to days" sheet: holds the selected
/// target days with per-day portion counts, computes allocation/conflict state,
/// builds the per-food scaled `FoodEntryCreate` payload, and submits it as one
/// atomic `POST /entries` batch. Pure state + math except for `submit()`.
import Foundation
import Observation

/// Observable model for selecting days and applying prep-batch portions to them.
@Observable
final class ApplyBatchModel {
    /// Discrete states of the apply action, kept Equatable for test assertions.
    enum SubmitState: Equatable {
        case idle
        case submitting
        case finished(entryCount: Int)
        case failed(PulseError)
    }

    /// One selected target day and how many portions land on it.
    struct DaySelection: Identifiable, Equatable {
        /// Canonical `yyyy-MM-dd` key for the day (matches `DateOnly.formatter`).
        let dayKey: String
        /// Midnight local on the target day.
        let date: Date
        var count: Int
        var id: String { dayKey }
    }

    private(set) var selections: [DaySelection] = []
    private(set) var submitState: SubmitState = .idle

    /// The batch items being applied (frozen macros from add time).
    let items: [BatchFoodItem]
    /// The batch's portion divisor (from `PrepModel.portions`).
    let portions: Int
    /// Day keys this batch was already applied to (drives the duplicate warning).
    let appliedDayKeys: Set<String>
    /// The unscaled sum of all items' macros, computed once at init (items are
    /// immutable) so per-day totals don't re-reduce on every render.
    let batchTotal: MacroTotals

    private weak var auth: AuthSession?
    /// Calendar used for day math throughout the model and bound views.
    let calendar: Calendar

    /// Creates an apply model for one batch.
    /// Inputs:
    ///   - items: the batch food items (each carries frozen macros).
    ///   - portions: the portion divisor, clamped to ≥ 1.
    ///   - appliedDayKeys: day keys already applied, for conflict flagging.
    ///   - auth: session used to build the API client at submit time.
    ///   - calendar: calendar for day math (injectable for tests).
    /// Outputs: an `ApplyBatchModel`.
    init(items: [BatchFoodItem], portions: Int, appliedDayKeys: Set<String>,
         auth: AuthSession?, calendar: Calendar = .current) {
        self.items = items
        self.portions = max(1, portions)
        self.appliedDayKeys = appliedDayKeys
        self.batchTotal = items.map(\.macros).reduce(.zero, +)
        self.auth = auth
        self.calendar = calendar
    }

    /// Adds the day to the selection at count 1, or removes it when already
    /// selected. Selections stay sorted by date.
    /// Inputs:
    ///   - date: any instant on the target day (normalized to local midnight).
    /// Outputs: nothing; mutates `selections`.
    func toggle(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        let key = DateOnly.formatter.string(from: day)
        if let idx = selections.firstIndex(where: { $0.dayKey == key }) {
            selections.remove(at: idx)
        } else {
            selections.append(DaySelection(dayKey: key, date: day, count: 1))
            selections.sort { $0.date < $1.date }
        }
    }

    /// True when the day is currently selected.
    /// Inputs:
    ///   - date: any instant on the day to check.
    /// Outputs: whether the day is in `selections`.
    func isSelected(_ date: Date) -> Bool {
        let key = DateOnly.formatter.string(from: calendar.startOfDay(for: date))
        return selections.contains { $0.dayKey == key }
    }

    /// Sets the portion count for an already-selected day (min 1); no-op when
    /// the day is not selected.
    /// Inputs:
    ///   - count: the new per-day portion count.
    ///   - dayKey: the selected day's key.
    /// Outputs: nothing; mutates `selections`.
    func setCount(_ count: Int, forDay dayKey: String) {
        guard let idx = selections.firstIndex(where: { $0.dayKey == dayKey }) else { return }
        selections[idx].count = max(1, count)
    }

    /// Total portions allocated across all selected days.
    var allocatedPortions: Int { selections.reduce(0) { $0 + $1.count } }

    /// True when more portions are allocated than the batch divides into.
    /// Warns in the UI; never blocks.
    var isOverAllocated: Bool { allocatedPortions > portions }

    /// Selected day keys that this batch was already applied to, date-ordered.
    var conflictedDayKeys: [String] {
        selections.map(\.dayKey).filter(appliedDayKeys.contains)
    }

    /// The macro total landing on one selected day (batch total x count/portions).
    /// Inputs:
    ///   - selection: the day selection to total.
    /// Outputs: the day's scaled `MacroTotals`.
    func dayTotal(for selection: DaySelection) -> MacroTotals {
        batchTotal.scaled(count: selection.count, portions: portions)
    }

    /// Builds the full `POST /entries` payload: one entry per (selected day x
    /// batch item), each scaled by that day's count over `portions`, carrying
    /// the item's real food source and `consumedAt` at noon local on the day.
    /// Items with neither a USDA nor a custom-food source are skipped (they
    /// cannot satisfy the server's source validator).
    /// Outputs: the ordered payload (days outer, items inner).
    func buildEntries() -> [FoodEntryCreate] {
        selections.flatMap { sel -> [FoodEntryCreate] in
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: sel.date) else {
                return []
            }
            let qty = "\(sel.count)/\(portions) of prep batch"
            return items.compactMap { item in
                let m = item.macros.scaled(count: sel.count, portions: portions)
                if let fdc = item.usdaFdcId {
                    return .usda(displayName: item.displayName, quantityText: qty,
                                 fdcId: fdc, usdaDescription: item.usdaDescription ?? item.displayName,
                                 calories: m.calories, proteinG: m.proteinG,
                                 carbsG: m.carbsG, fatG: m.fatG, consumedAt: noon)
                }
                if let customId = item.customFoodId {
                    return .custom(displayName: item.displayName, quantityText: qty,
                                   customFoodId: customId,
                                   calories: m.calories, proteinG: m.proteinG,
                                   carbsG: m.carbsG, fatG: m.fatG, consumedAt: noon)
                }
                return nil
            }
        }
    }

    /// Submits the payload as one atomic `POST /entries` batch. All-or-nothing:
    /// on failure nothing was logged and `submitState` carries the error (a 401
    /// additionally routes through `AuthSession`). Concurrent submits are
    /// rejected: if `submitState` is already `.submitting` this returns nil
    /// immediately. On success returns the applied day keys so the caller can
    /// record them for duplicate warnings.
    /// Outputs: the applied day keys on success, nil on failure or if already submitting.
    @discardableResult
    func submit() async -> Set<String>? {
        guard submitState != .submitting else { return nil }
        guard let client = auth?.makeClient() else {
            submitState = .failed(.notSignedIn)
            return nil
        }
        // Defensive backstop only: PrepView's canApply gate requires at least one
        // source-bearing item (see BatchFoodItem.hasSource), so an empty payload
        // is unreachable from the UI. Bail without faking a server error.
        let payload = buildEntries()
        guard !payload.isEmpty else { return nil }
        submitState = .submitting
        do {
            let resp = try await client.createEntries(payload)
            submitState = .finished(entryCount: resp.entries.count)
            return Set(selections.map(\.dayKey))
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            submitState = .failed(error)
            return nil
        } catch {
            submitState = .failed(.server(status: -1))
            return nil
        }
    }
}
