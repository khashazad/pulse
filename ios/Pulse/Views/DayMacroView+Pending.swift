/// Pending-items and swipe-action composition for `DayMacroView`, split out of
/// the main view file to keep each file focused. Holds the count pill, the
/// expandable pending panel, and the per-row swipe-action builders for both the
/// confirmed cluster rows and the pending panel rows.
import SwiftUI

extension DayMacroView {
    /// The underlying `FoodEntry`s for a grouped row (one for a single, all
    /// items for a meal group).
    /// - Parameter row: The grouped day row.
    /// - Returns: Its entries.
    func entries(of row: DayRow) -> [FoodEntry] {
        switch row {
        case .single(let entry): return [entry]
        case .meal(let group): return group.items
        }
    }

    /// Swipe actions for a confirmed row: Make Pending and Delete. A single-food
    /// delete defers immediately (with undo); a meal-group delete first asks for
    /// confirmation (it removes several entries at once).
    /// - Parameter row: The confirmed grouped row.
    /// - Returns: The trailing swipe actions.
    func confirmedRowActions(_ row: DayRow) -> [SwipeAction] {
        [
            SwipeAction(label: "Pending", systemImage: "clock.arrow.circlepath", tint: Theme.pending) {
                Task { await runMakePending(entries(of: row)) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal(let group):
                    mealDeletion = group.items
                    showMealDeleteConfirm = true
                }
            }
        ]
    }

    /// Runs a make-pending action and, on failure, stores the entries and raises
    /// the make-pending retry alert (mirroring how `runConfirm` surfaces confirm
    /// failures). On success the model has already reloaded the day.
    /// - Parameter entries: The entries to make pending.
    /// - Returns: Nothing; mutates view state on failure.
    func runMakePending(_ entries: [FoodEntry]) async {
        guard let model else { return }
        model.resetPendingState()
        await model.makePending(entries)
        if case .failed = model.pendingState {
            pendingRetry = entries
            showPendingFailure = true
        } else {
            pendingRetry = []
        }
    }

    /// Tappable count pill summarizing pending items; toggles the panel.
    /// - Parameter count: Number of pending entries.
    /// - Returns: The pill view.
    func pendingPill(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { pendingExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count) pending")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: pendingExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.pending)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.pending.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) pending items, tap to \(pendingExpanded ? "collapse" : "expand")")
    }

    /// Expanded panel listing each pending row, swipeable to Approve or Delete,
    /// with an "Approve all" action.
    /// - Parameters:
    ///   - rows: The pending rows.
    ///   - allPending: The flat pending entries (for "Approve all").
    /// - Returns: The panel view.
    func pendingPanel(_ rows: [DayRow], allPending: [FoodEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    SwipeActionsRow(actions: pendingRowActions(row)) {
                        switch row {
                        case .single(let entry): EntryRow(entry: entry)
                        case .meal(let group):   MealGroupRow(group: group)
                        }
                    }
                    if idx < rows.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .ctpCard(tint: Theme.pending.opacity(0.08))

            confirmAllBar(allPending)
        }
    }

    /// Swipe actions for a pending row: Approve (confirm) and Delete (deferred).
    /// - Parameter row: The pending grouped row.
    /// - Returns: The trailing swipe actions.
    func pendingRowActions(_ row: DayRow) -> [SwipeAction] {
        let pendingItems = entries(of: row).filter { !$0.isConfirmed }
        return [
            SwipeAction(label: "Approve", systemImage: "checkmark.circle", tint: Theme.CTP.green) {
                Task { await runConfirm(pendingItems) }
            },
            SwipeAction(label: "Delete", systemImage: "trash", tint: Theme.CTP.red, role: .destructive) {
                switch row {
                case .single(let entry):
                    model?.requestDelete([entry])
                case .meal:
                    mealDeletion = pendingItems
                    showMealDeleteConfirm = true
                }
            }
        ]
    }
}
