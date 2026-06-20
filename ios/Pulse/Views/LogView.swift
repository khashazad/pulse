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
                segmented
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                        .foregroundStyle(Theme.CTP.mauve)
                }
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

    private var title: String {
        switch subTab {
        case .today: "Today"
        case .week:  "This week"
        case .month: "This month"
        case .year:  "This year"
        }
    }

    private var segmented: some View {
        Picker("", selection: $subTab) {
            Text("Today").tag(LogSubTab.today)
            Text("Week").tag(LogSubTab.week)
            Text("Month").tag(LogSubTab.month)
            Text("Year").tag(LogSubTab.year)
        }
        .pickerStyle(.segmented)
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
    // Start at midnight so the graphical picker's own start-of-day
    // normalization on first layout doesn't fire `onChange` and flip
    // `hasPicked` before the user has actually tapped a day.
    @State private var selected: Date = Calendar.current.startOfDay(for: Date())
    /// Whether the user has actively tapped a day in the calendar yet. The
    /// "Open" action only surfaces after a real pick so the toolbar stays
    /// clean until there is a date to open.
    @State private var hasPicked = false

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
                    .onChange(of: selected) { _, _ in hasPicked = true }

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
                // has to scroll past the calendar to confirm. Shown only once a
                // day has actually been selected.
                if hasPicked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Open") { onOpen(selected) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                }
            }
        }
    }
}
