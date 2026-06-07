// Pulse/State/BatchCompositionModel.swift
/// Observable owner of the in-app meal-prep batch's food items. Pure state +
/// math (no networking): add/remove/replace items and sum their frozen macros.
/// `PrepView` persists `items` via `PrepStatePersistence`.
import Foundation
import Observation

/// View-model holding the batch's food items and their running macro total.
@Observable
final class BatchCompositionModel {
    private(set) var items: [BatchFoodItem] = []

    /// Seeds the model with previously persisted items.
    /// Inputs:
    ///   - items: items restored from persistence (defaults to empty).
    init(items: [BatchFoodItem] = []) {
        self.items = items
    }

    /// Appends an item to the batch.
    /// Inputs:
    ///   - item: the new batch item.
    func add(_ item: BatchFoodItem) {
        items.append(item)
    }

    /// Removes an item by id; no-op when absent.
    /// Inputs:
    ///   - id: the item id to remove.
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Replaces an item in place (matched by id), preserving order.
    /// Inputs:
    ///   - item: the edited item carrying an existing id.
    func replace(_ item: BatchFoodItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
    }

    /// The summed macros across all items.
    var total: MacroTotals {
        items.map(\.macros).reduce(.zero, +)
    }

    /// One portion's macros computed the same way the apply payload is built —
    /// each source-bearing item scaled individually (rounded like the submitted
    /// entries), then summed — so the Prep preview and the Apply sheet can never
    /// show different numbers for the same portion. Aggregate-then-scale (sum
    /// first, scale once) can round differently from the server's sum over the
    /// individually-scaled entries; this avoids that drift.
    /// Inputs:
    ///   - portions: the batch's portion divisor (clamped to ≥ 1 by `scaled`).
    /// Outputs: the per-portion `MacroTotals`, identical to one day's
    /// `ApplyBatchModel.dayTotal(for:)` at count 1.
    func perPortionTotal(portions: Int) -> MacroTotals {
        items.filter(\.hasSource)
            .map { $0.macros.scaled(count: 1, portions: portions) }
            .reduce(.zero, +)
    }
}
