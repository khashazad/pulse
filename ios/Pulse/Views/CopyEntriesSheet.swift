/// Backdating copy sheet for the day view.
/// Wraps the shared `BackdateSelector` and a confirm button that calls
/// `DayMacroModel.copyEntries`, used by `DayMacroView`'s multi-select flow.
import SwiftUI

/// Modal sheet for copying a set of existing entries onto a chosen day. Wraps the
/// shared `BackdateSelector` (defaulting to Today, since the common case is
/// "carry yesterday's items into today") and a confirm button that calls
/// `DayMacroModel.copyEntries`, reporting progress / partial-skip / failure
/// inline and dismissing on success.
struct CopyEntriesSheet: View {
    @Bindable var model: DayMacroModel
    let entries: [FoodEntry]
    /// Invoked after a successful copy so the host can leave select mode and refresh.
    let onCopied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()
    /// Entries still needing to be copied. Seeded from `entries` on first appear,
    /// then narrowed to the remainder after a partial failure so a retry only
    /// re-sends what hasn't already succeeded (no duplication).
    @State private var pending: [FoodEntry]?

    /// Whether a prior attempt failed partway, so the action becomes a retry of
    /// just the remaining entries.
    private var isRetry: Bool {
        if case .failed = model.copyState { return true }
        return false
    }

    /// The entries the next confirm will attempt (the full set on the first run,
    /// the remainder after a partial failure).
    private var work: [FoodEntry] { pending ?? entries }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Copy \(work.count) item\(work.count == 1 ? "" : "s") to which day?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.FG.secondary)

                    BackdateSelector(date: $date)
                        .padding(14)
                        .ctpCard()

                    statusRow

                    Spacer()

                    confirmButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle("Copy entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
            .onAppear { if pending == nil { pending = entries } }
        }
    }

    /// Inline status line reflecting the model's `copyState`: a partial-failure
    /// notice (telling the user how many already saved, so a retry is understood
    /// to resume rather than duplicate) or an "all skipped" notice. Full success
    /// dismisses the sheet via the confirm action, so it shows nothing here.
    @ViewBuilder
    private var statusRow: some View {
        switch model.copyState {
        case .failed(let copied, let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(error.userMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.CTP.red)
                if copied > 0 {
                    Text("\(copied) already saved — retry copies only the remaining \(work.count).")
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
            .font(.system(size: 12))
        case .finished(let copied, let skipped) where copied == 0 && skipped > 0:
            Label("Nothing to copy — \(skipped) item\(skipped == 1 ? "" : "s") had no recreatable source.", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.CTP.peach)
        default:
            EmptyView()
        }
    }

    /// Confirm button that triggers the copy; shows a spinner while copying,
    /// narrows `pending` to the remainder on partial failure, and dismisses only
    /// once at least one entry has actually been copied.
    private var confirmButton: some View {
        let isCopying = model.copyState == .copying
        let label = isCopying ? "Copying…" : (isRetry ? "Retry \(work.count) remaining" : "Copy entries")
        return PrimaryActionButton(
            title: label,
            leading: .busy(isCopying),
            disabled: isCopying || work.isEmpty
        ) {
            Task {
                let remaining = await model.copyEntries(work, to: date)
                pending = remaining
                if case .finished(let copied, _) = model.copyState, copied > 0 {
                    onCopied()
                    dismiss()
                }
            }
        }
    }
}
