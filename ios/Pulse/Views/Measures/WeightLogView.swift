/// Weight log sub-tab of the Measures screen.
///
/// Hosts `WeightLogView`, which loads entries via `WeightLogModel`, splits them
/// into a prominent "Today" card and a list of past weigh-ins (with per-row
/// deltas), and presents `WeightEntrySheet` for add/edit/delete actions.
/// Also defines the local `SheetState` enum that drives the entry sheet.
import SwiftUI

/// Main view for viewing and editing the user's daily weight log.
struct WeightLogView: View {
    @Environment(AuthSession.self) private var auth
    @State private var model: WeightLogModel?
    @State private var sheetState: SheetState?

    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    /// Drives which variant of `WeightEntrySheet` is presented.
    enum SheetState: Identifiable {
        case add(Date)
        case edit(WeightEntry)
        var id: String {
            switch self {
            case .add(let d): return "add-\(d)"
            case .edit(let e): return "edit-\(e.id)"
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            Group {
                switch model?.state ?? .idle {
                case .idle, .loading:
                    ProgressView().tint(Theme.CTP.mauve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let entries):
                    loadedBody(entries)
                case .failed(let err):
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't load",
                        description: err.userMessage,
                        action: { Task { await model?.load() } },
                        actionLabel: "Retry"
                    )
                }
            }
        }
        .task {
            if model == nil { model = WeightLogModel(auth: auth) }
            await model?.load()
        }
        .refreshable { await model?.load() }
        .sheet(item: $sheetState) { state in
            switch state {
            case .add(let date):
                WeightEntrySheet(
                    date: date,
                    existing: nil,
                    onSave: { value, unit in await model?.upsert(date: date, weight: value, unit: unit) },
                    onDelete: nil
                )
            case .edit(let entry):
                WeightEntrySheet(
                    date: entry.date,
                    existing: entry,
                    onSave: { value, unit in await model?.upsert(date: entry.date, weight: value, unit: unit) },
                    onDelete: { await model?.delete(date: entry.date) }
                )
            }
        }
    }

    /// Renders the loaded list of weight entries split into Today + Past sections.
    ///
    /// Inputs:
    /// - entries: the loaded entries; this method sorts and partitions internally.
    ///
    /// Outputs: the composed scroll view.
    @ViewBuilder
    private func loadedBody(_ entries: [WeightEntry]) -> some View {
        let displayUnit = WeightUnit(rawValue: displayUnitRaw) ?? .lb
        let sorted = entries.sorted { $0.date > $1.date }
        let today = Calendar.current.startOfDay(for: Date())
        let todayEntry = sorted.first { Calendar.current.startOfDay(for: $0.date) == today }
        let past = sorted.filter { Calendar.current.startOfDay(for: $0.date) != today }

        ScrollView {
            VStack(spacing: Theme.Layout.sectionSpacing) {
                todayCard(today: today, entry: todayEntry, unit: displayUnit)
                pastSection(past: past, unit: displayUnit)
                Spacer(minLength: Theme.Layout.dockClearance)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    /// Builds the top "Today" card with either the current weigh-in or an add prompt,
    /// plus a tap-to-toggle lb/kg display unit chip.
    ///
    /// Inputs:
    /// - today: the start-of-day date for today.
    /// - entry: today's entry if present, else nil.
    /// - unit: current display unit.
    ///
    /// Outputs: the today-card `View`.
    private func todayCard(today: Date, entry: WeightEntry?, unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                Button {
                    displayUnitRaw = (unit == .lb ? WeightUnit.kg : .lb).rawValue
                } label: {
                    Text(unit.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.FG.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.CTP.surface1.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
            }
            if let entry {
                Button {
                    sheetState = .edit(entry)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(WeightFormatter.entryString(WeightFormatter.fromLb(entry.weightLb, to: unit)))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.FG.primary)
                            .monospacedDigit()
                        Text(unit.rawValue)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.FG.tertiary)
                        Spacer()
                        Text("tap to edit")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.FG.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    sheetState = .add(today)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add today's weight")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.CTP.mauve)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .ctpCard()
    }

    /// Renders the "Past" section, capped to the 12 most recent prior entries.
    ///
    /// Inputs:
    /// - past: entries from days other than today, sorted newest first.
    /// - unit: current display unit.
    ///
    /// Outputs: the past-section `View`.
    private func pastSection(past: [WeightEntry], unit: WeightUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Past")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                Spacer()
                if !past.isEmpty {
                    Text("\(past.count) \(past.count == 1 ? "entry" : "entries")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.FG.tertiary)
                }
            }
            .padding(.horizontal, 4)

            if past.isEmpty {
                Text("No past weigh-ins.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.FG.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ctpCard()
            } else {
                let rows = Array(past.prefix(12).enumerated())
                VStack(spacing: 0) {
                    ForEach(rows, id: \.element.id) { idx, entry in
                        let next = past.indices.contains(idx + 1) ? past[idx + 1] : nil
                        let delta = next.map { entry.weightLb - $0.weightLb }
                        pastRow(entry: entry, delta: delta, unit: unit)
                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .ctpCard()
            }
        }
    }

    /// Renders one row of the Past section with date, day-over-day delta, and weight.
    ///
    /// Inputs:
    /// - entry: the entry shown by this row.
    /// - delta: difference in pounds from the next-older entry, or nil if unknown.
    /// - unit: current display unit.
    ///
    /// Outputs: a tappable past-row `View` that opens the edit sheet.
    private func pastRow(entry: WeightEntry, delta: Double?, unit: WeightUnit) -> some View {
        Button {
            sheetState = .edit(entry)
        } label: {
            HStack(spacing: 10) {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.FG.primary)
                Spacer()
                if let delta {
                    Text("\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(deltaColor(delta))
                }
                Text(WeightFormatter.display(lb: entry.weightLb, in: unit))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.FG.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.FG.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Picks a foreground color for a delta value: peach for gains, green for losses,
    /// tertiary gray within the ±0.1 lb noise band.
    ///
    /// Inputs:
    /// - delta: difference in pounds.
    ///
    /// Outputs: the color to use for that delta.
    private func deltaColor(_ delta: Double) -> Color {
        if delta > 0.1 { return Theme.CTP.peach }
        if delta < -0.1 { return Theme.CTP.green }
        return Theme.FG.tertiary
    }
}
