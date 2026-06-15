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
    /// The source-bearing items — the only ones the payload can log. Computed
    /// once at init (items are immutable); the single item list behind the
    /// review rows, the day totals, and the payload, so they cannot diverge.
    let applicableItems: [BatchFoodItem]

    private weak var auth: AuthSession?
    /// Calendar used for day math throughout the model and bound views.
    let calendar: Calendar
    /// Local midnight of "today" — the boundary between confirmed (today/past)
    /// and pending (strictly future) applied entries. Captured at init so the
    /// confirmed/pending split is deterministic and injectable for tests.
    let referenceDay: Date

    /// Creates an apply model for one batch.
    /// Inputs:
    ///   - items: the batch food items (each carries frozen macros).
    ///   - portions: the portion divisor, clamped to ≥ 1.
    ///   - appliedDayKeys: day keys already applied, for conflict flagging.
    ///   - auth: session used to build the API client at submit time.
    ///   - calendar: calendar for day math (injectable for tests).
    ///   - now: reference instant for "today"; injectable for deterministic tests.
    /// Outputs: an `ApplyBatchModel`.
    init(items: [BatchFoodItem], portions: Int, appliedDayKeys: Set<String>,
         auth: AuthSession?, calendar: Calendar = .current, now: Date = Date()) {
        self.items = items
        self.portions = max(1, portions)
        self.appliedDayKeys = appliedDayKeys
        self.applicableItems = items.filter(\.hasSource)
        self.auth = auth
        self.calendar = calendar
        self.referenceDay = calendar.startOfDay(for: now)
    }

    /// Whether entries applied to the given selection should land pending
    /// (unconfirmed). True only for days strictly after `referenceDay`; today
    /// and past days are confirmed immediately.
    /// Inputs:
    ///   - selection: the day selection to classify.
    /// Outputs: `true` when the day is in the future and entries should be pending.
    func isPending(_ selection: DaySelection) -> Bool {
        selection.date > referenceDay
    }

    /// Adds the day to the selection at count 1, or removes it when already
    /// selected. Selections stay sorted by date.
    /// Inputs:
    ///   - date: any instant on the target day (normalized to local midnight).
    /// Outputs: nothing; mutates `selections`.
    func toggle(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        let key = DateOnly.string(from: day)
        if let idx = selections.firstIndex(where: { $0.dayKey == key }) {
            selections.remove(at: idx)
        } else {
            selections.append(DaySelection(dayKey: key, date: day, count: 1))
            selections.sort { $0.date < $1.date }
        }
    }

    /// True when the day with the given canonical key is currently selected.
    /// Inputs:
    ///   - dayKey: the day's `yyyy-MM-dd` key.
    /// Outputs: whether the day is in `selections`.
    func isSelected(dayKey: String) -> Bool {
        selections.contains { $0.dayKey == dayKey }
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

    /// The macro total landing on one selected day: the sum of the SAME
    /// per-item scaled values the payload carries (per-item rounding, source-
    /// bearing items only) — never an aggregate-then-scale, which can round
    /// differently from what the server sums over the submitted entries.
    /// Inputs:
    ///   - selection: the day selection to total.
    /// Outputs: the day's `MacroTotals`, exactly matching the submitted entries.
    func dayTotal(for selection: DaySelection) -> MacroTotals {
        applicableItems
            .map { scaledMacros(for: $0, in: selection) }
            .reduce(.zero, +)
    }

    /// The macros one batch item contributes to one selected day (item macros
    /// x count/portions). Single source of truth for the review preview and the
    /// submitted payload, so the two cannot drift.
    /// Inputs:
    ///   - item: the batch item.
    ///   - selection: the day selection supplying the portion count.
    /// Outputs: the item's scaled `MacroTotals` for that day.
    func scaledMacros(for item: BatchFoodItem, in selection: DaySelection) -> MacroTotals {
        item.macros.scaled(count: selection.count, portions: portions)
    }

    /// Builds one selected day's payload entries: one entry per item in
    /// `applicableItems`, scaled via `scaledMacros(for:in:)`, carrying the
    /// item's real food source and `consumedAt` mid-day local on the day (the
    /// canonical `DateOnly.noon` anchor).
    /// Inputs:
    ///   - sel: the day selection to build entries for.
    /// Outputs: the day's payload entries (empty only for an all-sourceless batch).
    private func entries(for sel: DaySelection) -> [FoodEntryCreate] {
        let qty = "\(sel.count)/\(portions) of prep batch"
        // Future days land pending; today/past are confirmed immediately.
        let confirmed = !isPending(sel)
        // Pending portions anchor at end-of-day so they sort to the end of the
        // day's list once confirmed; confirmed (today/past) portions keep the
        // canonical mid-day anchor.
        let anchor = confirmed
            ? DateOnly.noon(on: sel.date, calendar: calendar)
            : DateOnly.endOfDay(on: sel.date, calendar: calendar)
        return applicableItems.compactMap { item in
            let m = scaledMacros(for: item, in: sel)
            if let fdc = item.usdaFdcId {
                return .usda(displayName: item.displayName, quantityText: qty,
                             fdcId: fdc, usdaDescription: item.usdaDescription ?? item.displayName,
                             calories: m.calories, proteinG: m.proteinG,
                             carbsG: m.carbsG, fatG: m.fatG, consumedAt: anchor,
                             confirmed: confirmed)
            }
            if let customId = item.customFoodId {
                return .custom(displayName: item.displayName, quantityText: qty,
                               customFoodId: customId,
                               calories: m.calories, proteinG: m.proteinG,
                               carbsG: m.carbsG, fatG: m.fatG, consumedAt: anchor,
                               confirmed: confirmed)
            }
            return nil
        }
    }

    /// The per-day payload contributions: each selected day paired with the
    /// entries it would log, in selection order. Single source of truth for both
    /// the flat payload (`buildEntries`) and `submit()`, so the value tested in
    /// unit tests is exactly the value production submits.
    /// Outputs: ordered `(dayKey, entries)` pairs, one per selected day.
    func contributions() -> [(dayKey: String, entries: [FoodEntryCreate])] {
        selections.map { (dayKey: $0.dayKey, entries: entries(for: $0)) }
    }

    /// Builds the full `POST /entries` payload: one entry per (selected day x
    /// source-bearing batch item).
    /// Outputs: the ordered payload (days outer, items inner).
    func buildEntries() -> [FoodEntryCreate] {
        contributions().flatMap(\.entries)
    }

    /// Submits the payload as one atomic `POST /entries` batch. All-or-nothing:
    /// on failure nothing was logged and `submitState` carries the error (a 401
    /// additionally routes through `AuthSession`). Concurrent submits are
    /// rejected: if `submitState` is already `.submitting` this returns nil
    /// immediately. The payload comes from `contributions()` — the same builder
    /// the unit tests exercise — so what is tested is exactly what is sent. On
    /// success returns the day keys derived from the contributions that actually
    /// carried entries (never raw selections), so the caller's duplicate-warning
    /// memory can only record days that truly received entries.
    /// Outputs: the applied day keys on success, nil on failure, cancellation,
    /// or if already submitting.
    @discardableResult
    func submit() async -> Set<String>? {
        guard submitState != .submitting else { return nil }
        guard let client = auth?.makeClient() else {
            submitState = .failed(.notSignedIn)
            return nil
        }
        let contributions = self.contributions()
        let payload = contributions.flatMap(\.entries)
        // canApply (PrepView) requires a source-bearing item and selection
        // counts clamp to ≥ 1, so a non-empty selection always yields a
        // non-empty payload — an empty payload is unreachable from the UI.
        guard !payload.isEmpty else {
            assertionFailure("unreachable: canApply gates empty payloads")
            return nil
        }
        submitState = .submitting
        do {
            let resp = try await client.createEntries(payload)
            submitState = .finished(entryCount: resp.entries.count)
            return Set(contributions.filter { !$0.entries.isEmpty }.map(\.dayKey))
        } catch is CancellationError {
            // The task was cancelled (e.g. the sheet was dismissed mid-flight):
            // not a failure to surface. Reset to idle and report nothing applied.
            submitState = .idle
            return nil
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            submitState = .failed(error)
            return nil
        } catch let urlError as URLError {
            // A transport error that escaped the client without being wrapped:
            // classify it truthfully as a network failure, never a server fault.
            submitState = .failed(.network(urlError))
            return nil
        } catch {
            // The only remaining escapees are local, non-transport errors (e.g.
            // request-body encoding) that never reached the server. PulseError
            // has no encoding case; .decoding carries a description and is the
            // least-misleading existing case for "couldn't build/handle the
            // payload locally" — emphatically not a server fault.
            submitState = .failed(.decoding(error.localizedDescription))
            return nil
        }
    }
}
