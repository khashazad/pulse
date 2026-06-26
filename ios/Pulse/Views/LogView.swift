/// Intake-tab root screen.
/// Hosts a segmented sub-tab control (Today / Week / Month / Year) that swaps in
/// `DayMacroView`, `WeekView`, `MonthView`, or `YearView`. Also exposes a calendar
/// toolbar button that opens `DatePickerSheet` for navigating to an arbitrary day
/// (past or future).
import SwiftUI

/// Sub-tab identifiers used by the segmented control inside `LogView`.
enum LogSubTab: Hashable {
    case today, week, month, year
}

/// Intake-tab content: segmented period picker plus a date-picker toolbar action.
/// Calls `onOpenDate` when the user picks a specific day to drill into.
struct LogView: View {
    @State private var subTab: LogSubTab = .today
    @State private var showDatePicker = false
    let onOpenDate: (Date) -> Void

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                periodBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                content
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(onOpen: { date in
                showDatePicker = false
                onOpenDate(date)
            })
            .presentationDetents([.medium, .large])
        }
    }

    /// Top period selector: Today/Week/Month/Year toggle chips plus a "Pick a
    /// date" action chip that opens the date picker. A non-scrolling row so it
    /// never competes with the section pager's horizontal swipe.
    /// - Returns: A single row of period chips.
    private var periodBar: some View {
        HStack(spacing: 8) {
            periodChip("Today", .today)
            periodChip("Week", .week)
            periodChip("Month", .month)
            periodChip("Year", .year)
            Spacer(minLength: 6)
            Button { showDatePicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 12, weight: .semibold))
                    Text("Pick a date").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.FG.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Layout.chipRadius)
                    .fill(Theme.BG.tertiary))
            }
            .buttonStyle(.plain)
        }
    }

    /// A single period toggle chip.
    /// - Parameters:
    ///   - label: The chip's display text.
    ///   - tab: The period this chip selects when tapped.
    /// - Returns: A pill button that selects `tab` and highlights when it is current.
    private func periodChip(_ label: String, _ tab: LogSubTab) -> some View {
        let active = subTab == tab
        return Button { subTab = tab } label: {
            Text(label).font(.system(size: 13, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.CTP.base : Theme.FG.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Layout.chipRadius)
                    .fill(active ? Theme.tint : Theme.BG.tertiary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch subTab {
        case .today:
            DayMacroView(date: Date())
        case .week:
            WeekView()
        case .month:
            MonthView()
        case .year:
            YearView()
        }
    }
}

/// Modal date-picker sheet used by `LogView` to jump to an arbitrary day,
/// past or future (future days show pre-logged "planned" entries).
/// Calls `onOpen` with the chosen date when the user confirms.
struct DatePickerSheet: View {
    let onOpen: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    // Start at midnight so the row reads as a clean calendar day. Today is the
    // default selection, so "Open" is meaningful immediately — the sheet always
    // has a valid date to open.
    @State private var selected: Date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(spacing: 16) {
                    DatePicker(
                        "Pick a date",
                        selection: $selected,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .tint(Theme.CTP.mauve)
                    .padding(.horizontal, 12)

                    Spacer()
                }
                .padding(.top, 4)
            }
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
                // Sits beside "Cancel" on the navigation bar so the user never
                // has to scroll past the calendar to confirm.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open") { onOpen(selected) }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
    }
}
