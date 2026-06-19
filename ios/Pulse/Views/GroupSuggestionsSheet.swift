/// Sheet listing every detected grouping cluster so the user can pick which one
/// to merge (or back out). Presented from `FoodTabView` when more than one
/// cluster exists; tapping a row hands that cluster back via `onPick`.
import SwiftUI

/// A chooser over the duplicate clusters found among standalone custom foods.
struct GroupSuggestionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The clusters to choose from (each has >= 2 foods).
    let clusters: [[CustomFood]]
    /// Invoked with the chosen cluster; the host enters selection mode with it.
    let onPick: ([CustomFood]) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(clusters.enumerated()), id: \.offset) { idx, cluster in
                            if idx > 0 {
                                Rectangle().fill(Theme.separator).frame(height: 0.5)
                            }
                            row(cluster)
                        }
                    }
                    .padding(.horizontal, 14)
                    .ctpCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
            }
            .navigationTitle("Merge suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
        }
    }

    /// One tappable suggestion row: the suggested food name plus its members.
    /// Inputs:
    ///   - cluster: the cluster of standalone foods this row represents.
    /// Outputs: the composed row view.
    private func row(_ cluster: [CustomFood]) -> some View {
        Button {
            onPick(cluster)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.CTP.mauve)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FoodDuplicateGrouper.suggestedName(for: cluster))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.FG.primary)
                    Text(cluster.map(\.name).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.FG.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
