/// Photos sub-tab of the Measures screen.
///
/// Hosts `ProgressPhotosView`, which renders a date strip, a 2×2 grid of
/// `ProgressPhotoSlotCell`s for the currently selected date, an Add button
/// that presents `PhotoCaptureSession`, and a sync-status footer. Also
/// triggers `ProgressPhotoStore.reconcile` over a 30-day window when the
/// selected date changes or on pull-to-refresh.
import SwiftUI

/// Top-level view for browsing and capturing progress photos by date.
struct ProgressPhotosView: View {
    @Environment(ProgressPhotoStore.self) private var store
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showCapture = false

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Layout.sectionSpacing) {
                    dateStrip
                    grid
                    addButton
                    syncFooter
                    Spacer(minLength: Theme.Layout.dockClearance)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .task { await reloadRange() }
        .refreshable { await reloadRange() }
        .onChange(of: selectedDate) { _, _ in
            Task { await reloadRange() }
        }
        .sheet(isPresented: $showCapture) {
            PhotoCaptureSession(date: selectedDate)
        }
    }

    // MARK: date strip

    private var dateStrip: some View {
        HStack(spacing: 8) {
            chip("Today") { selectedDate = Calendar.current.startOfDay(for: Date()) }
            chip("−1") { shift(-1) }
            chip("−7") { shift(-7) }
            Spacer()
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.CTP.mauve)
        }
    }

    /// Renders a small capsule button in the date strip.
    ///
    /// Inputs:
    /// - label: visible text on the chip.
    /// - action: closure invoked on tap.
    ///
    /// Outputs: the styled chip `View`.
    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.BG.secondary, in: Capsule())
            .foregroundStyle(Theme.FG.primary)
    }

    /// Shifts the selected date by the given number of days, snapping to day start.
    ///
    /// Inputs:
    /// - days: positive or negative day offset from the current `selectedDate`.
    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = Calendar.current.startOfDay(for: d)
        }
    }

    // MARK: grid

    private var grid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(ProgressPhotoSlot.allCases, id: \.self) { slot in
                ProgressPhotoSlotCell(date: selectedDate, slot: slot) {
                    showCapture = true
                }
            }
        }
    }

    // MARK: add + sync footer

    private var addButton: some View {
        Button { showCapture = true } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add photos")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.CTP.mauve)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Theme.BG.secondary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var syncFooter: some View {
        Group {
            if store.pendingCount == 0 {
                Text("All synced")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            } else {
                Text("\(store.pendingCount) pending…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
    }

    // MARK: range refresh

    /// Reconciles the 30 days leading up to `selectedDate` with the server.
    private func reloadRange() async {
        let from = Calendar.current.date(byAdding: .day, value: -30, to: selectedDate) ?? selectedDate
        await store.reconcile(from: from, to: selectedDate)
    }
}
