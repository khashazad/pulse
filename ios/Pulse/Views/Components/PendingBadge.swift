/// Small "pending" pill marking a food entry (or meal group) that has been
/// applied to a future day but not yet confirmed, so it does not count toward
/// the day's totals. Shared by `EntryRow` and `MealGroupRow`.
import SwiftUI

/// A peach "pending" capsule label.
struct PendingBadge: View {
    var body: some View {
        Text("pending")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.CTP.peach)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.CTP.peach.opacity(0.16))
            )
    }
}
