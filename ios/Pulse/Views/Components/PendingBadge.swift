/// Small "pending" pill marking a food entry (or meal group) that has been
/// applied to a future day but not yet confirmed, so it does not count toward
/// the day's totals. Shared by `EntryRow` and `MealGroupRow`.
import SwiftUI

/// A sky "pending" capsule label. Sky (not peach) keeps the badge distinct from
/// the Fat macro color, which is now peach.
struct PendingBadge: View {
    var body: some View {
        Text("pending")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.pending)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.pending.opacity(0.16))
            )
    }
}
