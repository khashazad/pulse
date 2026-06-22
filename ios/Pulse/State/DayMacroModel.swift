/// DayMacroModel: view-model that loads a single day's macro summary and
/// coordinates copy and delete actions on that day's food entries.
/// Wraps PulseClient.summary() in a LoadState and routes unauthorized
/// errors through AuthSession.
/// Role: backing model for any view that displays a one-day macro readout.
import Foundation
import Observation

/// Observable view-model wrapping the daily macro summary endpoint for a fixed date.
@Observable
final class DayMacroModel {
    let date: Date
    private(set) var state: LoadState<DailySummary> = .idle
    /// Outcome of the most recent "copy entries to another day" action.
    private(set) var copyState: CopyState = .idle
    /// Outcome of the most recent "delete selected entries" action.
    private(set) var deleteState: DeleteState = .idle
    /// Outcome of the most recent "confirm pending entries" action.
    private(set) var confirmState: ConfirmState = .idle
    /// Outcome of the most recent "make pending" (unconfirm) action.
    private(set) var pendingState: PendingState = .idle
    private weak var auth: AuthSession?

    /// Discrete states of a copy-entries action, kept separate from `state` so the
    /// copy sheet can show progress / success / failure without disturbing the
    /// day's displayed summary.
    ///
    /// `failed` carries the number of entries that were already persisted before
    /// the failure (`copied`) so the UI never presents a total failure that hides
    /// committed writes — and so a retry can resume from the remainder instead of
    /// re-sending (and duplicating) what already succeeded.
    enum CopyState: Equatable {
        case idle
        case copying
        case finished(copied: Int, skipped: Int)
        case failed(copied: Int, error: PulseError)
    }

    /// Discrete states of a delete-entries action, kept separate from `state`
    /// (like `CopyState`) so the confirmation/alert flow can show progress and
    /// failure without disturbing the day's displayed summary.
    ///
    /// `failed` carries the number of entries already deleted before the failure
    /// so the UI never presents a total failure that hides committed deletes —
    /// and so a retry can resume from the remainder instead of re-sending
    /// deletes for entries that are already gone.
    enum DeleteState: Equatable {
        case idle
        case deleting
        case finished(deleted: Int)
        case failed(deleted: Int, error: PulseError)
    }

    /// Discrete states of a confirm-entries action. Confirming is one atomic
    /// `POST /entries/confirm` over all selected ids (unlike copy/delete, which
    /// loop per entry), so there is no partial-failure remainder to track.
    enum ConfirmState: Equatable {
        case idle
        case confirming
        case finished(confirmed: Int)
        case failed(PulseError)
    }

    /// Discrete states of a make-pending (unconfirm) action — the inverse of
    /// confirm. One atomic `POST /entries/unconfirm` over all selected ids, so
    /// there is no partial-failure remainder to track.
    enum PendingState: Equatable {
        case idle
        case working
        case finished(count: Int)
        case failed(PulseError)
    }

    /// Initializes the model for a specific calendar day.
    /// Inputs:
    ///   - date: the day whose summary will be fetched.
    ///   - auth: auth session used to construct an authenticated client.
    init(date: Date, auth: AuthSession) {
        self.date = date
        self.auth = auth
    }

    /// Fetches the daily summary and updates `state`; routes 401 through AuthSession.
    func load() async {
        guard let client = auth?.makeClient() else {
            state = .failed(.notSignedIn)
            return
        }
        state = .loading
        do {
            let summary = try await client.summary(date: date)
            state = .loaded(summary)
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            state = .failed(error)
        } catch {
            state = .failed(.server(status: -1))
        }
    }

    /// Copies the given existing entries onto a target day as fresh food entries.
    ///
    /// Each entry is recreated from its own source (USDA or custom food) with
    /// `consumedAt` set to `targetDay`, so the server attributes them to that
    /// day's log. Entries are sent one per request (rather than as one batch) so
    /// each lands as a standalone entry instead of being grouped into an anonymous
    /// "Meal" row. Entries that reference neither a USDA food nor a custom food
    /// are skipped and counted.
    ///
    /// The loop stops at the first request failure rather than aborting the whole
    /// batch: everything already created stays created, `copyState` records how
    /// many succeeded, and the **returned array is the entries still needing to be
    /// copied** (the one that failed plus any not yet attempted). Callers should
    /// retry with exactly that array so a transient failure mid-batch never
    /// duplicates the entries that already succeeded. Routes a 401 through
    /// `AuthSession`.
    /// - Parameters:
    ///   - entries: The source entries to copy (a full set, or a remainder from a
    ///     prior partial run).
    ///   - targetDay: The day to attribute the copies to (used as `consumed_at`).
    /// - Returns: The entries that were **not** copied and remain safe to retry —
    ///   empty when every recreatable entry was copied. (Unrecreatable entries are
    ///   counted as `skipped`, not returned, since retrying them cannot help.)
    @discardableResult
    func copyEntries(_ entries: [FoodEntry], to targetDay: Date) async -> [FoodEntry] {
        guard let client = auth?.makeClient() else {
            copyState = .failed(copied: 0, error: .notSignedIn)
            return entries
        }
        copyState = .copying
        var copied = 0
        var skipped = 0
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard let payload = Self.makeCreate(from: entry, consumedAt: targetDay) else {
                skipped += 1
                index += 1
                continue
            }
            do {
                _ = try await client.createEntries([payload])
                copied += 1
                index += 1
            } catch let error as PulseError {
                if error == .unauthorized { auth?.handleUnauthorized() }
                copyState = .failed(copied: copied, error: error)
                return Array(entries[index...])
            } catch {
                copyState = .failed(copied: copied, error: .server(status: -1))
                return Array(entries[index...])
            }
        }
        copyState = .finished(copied: copied, skipped: skipped)
        return []
    }

    /// Resets the copy action back to idle so stale success/failure state doesn't
    /// leak across sheet presentations (called before each present).
    /// - Returns: Nothing.
    func resetCopyState() {
        copyState = .idle
    }

    /// Deletes the given entries on the server, one `DELETE /entries/{id}` per
    /// entry (mirroring how `copyEntries` loops single POSTs).
    ///
    /// The loop stops at the first request failure rather than aborting the
    /// whole batch: everything already deleted stays deleted, `deleteState`
    /// records how many succeeded, and the **returned array is the entries
    /// still needing deletion** (the one that failed plus any not yet
    /// attempted). Callers should retry with exactly that array so a transient
    /// failure mid-batch never re-targets entries that are already gone.
    ///
    /// A `.notFound` (404) response counts as a successful delete — the entry
    /// is already gone, which is the outcome the user wanted — and the loop
    /// continues. Routes a 401 through `AuthSession`.
    /// - Parameters:
    ///   - entries: The entries to delete (a full selection, or a remainder
    ///     from a prior partial run).
    /// - Returns: The entries that were **not** deleted and remain safe to
    ///   retry — empty when every entry was deleted (or already gone).
    @discardableResult
    func deleteEntries(_ entries: [FoodEntry]) async -> [FoodEntry] {
        guard let client = auth?.makeClient() else {
            deleteState = .failed(deleted: 0, error: .notSignedIn)
            return entries
        }
        deleteState = .deleting
        var deleted = 0
        var index = 0
        while index < entries.count {
            do {
                try await client.deleteEntry(id: entries[index].id)
                deleted += 1
                index += 1
            } catch PulseError.notFound {
                // Already gone on the server — count as deleted and move on.
                deleted += 1
                index += 1
            } catch let error as PulseError {
                if error == .unauthorized { auth?.handleUnauthorized() }
                deleteState = .failed(deleted: deleted, error: error)
                return Array(entries[index...])
            } catch {
                deleteState = .failed(deleted: deleted, error: .server(status: -1))
                return Array(entries[index...])
            }
        }
        deleteState = .finished(deleted: deleted)
        return []
    }

    /// Resets the delete action back to idle so stale success/failure state
    /// doesn't leak across confirmation flows (called before each run).
    /// - Returns: Nothing.
    func resetDeleteState() {
        deleteState = .idle
    }

    /// Confirms pending entries in one atomic `POST /entries/confirm`, then
    /// reloads the day so the now-confirmed entries fold into the totals.
    ///
    /// Used by the day view to confirm a single pending prep entry or all of a
    /// day's pending entries at once. The server confirm is idempotent, so a
    /// retry after a transient failure is safe. Routes a 401 through
    /// `AuthSession`. A no-op (empty input) finishes immediately without a
    /// request.
    /// - Parameters:
    ///   - entries: The pending entries to confirm.
    /// - Returns: Nothing; updates `confirmState` and, on success, reloads `state`.
    func confirmEntries(_ entries: [FoodEntry]) async {
        guard let client = auth?.makeClient() else {
            confirmState = .failed(.notSignedIn)
            return
        }
        let ids = entries.map(\.id)
        guard !ids.isEmpty else {
            confirmState = .finished(confirmed: 0)
            return
        }
        confirmState = .confirming
        do {
            let response = try await client.confirmEntries(ids: ids)
            confirmState = .finished(confirmed: response.entries.count)
            await load()
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            confirmState = .failed(error)
        } catch {
            confirmState = .failed(.server(status: -1))
        }
    }

    /// Resets the confirm action back to idle so stale success/failure state
    /// doesn't leak across presentations (called before each run).
    /// - Returns: Nothing.
    func resetConfirmState() {
        confirmState = .idle
    }

    /// Moves the given confirmed entries back to pending in one atomic `POST
    /// /entries/unconfirm`, then reloads the day so the now-pending entries drop
    /// out of the totals. The inverse of `confirmEntries`. Routes a 401 through
    /// `AuthSession`. A no-op (empty input) finishes immediately without a
    /// request.
    /// - Parameters:
    ///   - entries: The confirmed entries to make pending.
    /// - Returns: Nothing; updates `pendingState` and, on success, reloads `state`.
    func makePending(_ entries: [FoodEntry]) async {
        guard let client = auth?.makeClient() else {
            pendingState = .failed(.notSignedIn)
            return
        }
        let ids = entries.map(\.id)
        guard !ids.isEmpty else {
            pendingState = .finished(count: 0)
            return
        }
        pendingState = .working
        do {
            let response = try await client.makePending(ids: ids)
            pendingState = .finished(count: response.entries.count)
            await load()
        } catch let error as PulseError {
            if error == .unauthorized { auth?.handleUnauthorized() }
            pendingState = .failed(error)
        } catch {
            pendingState = .failed(.server(status: -1))
        }
    }

    /// Resets the make-pending action back to idle so stale success/failure state
    /// doesn't leak across presentations.
    /// - Returns: Nothing.
    func resetPendingState() {
        pendingState = .idle
    }

    /// Builds a `FoodEntryCreate` that reproduces an existing entry on a new day.
    ///
    /// Preserves the display name, quantity text, normalized quantity, and macros
    /// verbatim, choosing the USDA or custom-food factory based on which source the
    /// entry carries.
    /// - Parameters:
    ///   - entry: The source entry to reproduce.
    ///   - consumedAt: The backdated consumption time for the copy.
    /// - Returns: A `FoodEntryCreate` mirroring `entry`, or `nil` when the entry
    ///   references neither a USDA food nor a custom food (and thus cannot be
    ///   recreated through `POST /entries`).
    static func makeCreate(from entry: FoodEntry, consumedAt: Date) -> FoodEntryCreate? {
        if let fdcId = entry.usdaFdcId, let description = entry.usdaDescription {
            return .usda(
                displayName: entry.displayName,
                quantityText: entry.quantityText,
                fdcId: fdcId,
                usdaDescription: description,
                calories: entry.calories,
                proteinG: entry.proteinG,
                carbsG: entry.carbsG,
                fatG: entry.fatG,
                normalizedQuantityValue: entry.normalizedQuantityValue,
                normalizedQuantityUnit: entry.normalizedQuantityUnit,
                consumedAt: consumedAt
            )
        }
        if let customFoodId = entry.customFoodId {
            return .custom(
                displayName: entry.displayName,
                quantityText: entry.quantityText,
                customFoodId: customFoodId,
                calories: entry.calories,
                proteinG: entry.proteinG,
                carbsG: entry.carbsG,
                fatG: entry.fatG,
                normalizedQuantityValue: entry.normalizedQuantityValue,
                normalizedQuantityUnit: entry.normalizedQuantityUnit,
                consumedAt: consumedAt
            )
        }
        return nil
    }
}
