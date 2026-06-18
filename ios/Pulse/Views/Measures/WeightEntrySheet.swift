/// Modal sheet for adding or editing a single day's weight reading.
///
/// Converts between the user's preferred display unit (lb/kg via `@AppStorage`)
/// and storage in pounds, validates the numeric input, and reports save/delete
/// back via callbacks so the parent (`WeightLogView`) drives persistence.
///
/// In `editableDate` mode it also renders a `DatePicker` (bounded to
/// `lowerBound ... today`) so the user can backfill a missed day; the
/// "exists / prefill / delete-visible" state is derived from `lookupEntry`.
import SwiftUI

/// Bottom sheet for entering/editing a weight on a given date.
///
/// Inputs:
/// - date: the initial date this entry applies to.
/// - editableDate: when true, show a `DatePicker` and let the user change the day.
/// - lowerBound: earliest selectable date (only consulted when `editableDate`).
/// - lookupEntry: resolves the existing entry for a day, if any; drives title,
///   prefill, and delete-button visibility. Defaults to "no entry".
/// - onSave: async callback receiving the chosen date, parsed value, and unit.
/// - onDelete: async callback receiving the date to delete.
struct WeightEntrySheet: View {
    let date: Date
    var editableDate: Bool = false
    var lowerBound: Date = .distantPast
    var lookupEntry: (Date) -> WeightEntry? = { _ in nil }
    let onSave: (Date, Double, WeightUnit) async -> Void
    let onDelete: (Date) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @State private var selectedDate: Date = Date()
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    private var unit: WeightUnit {
        WeightUnit(rawValue: displayUnitRaw) ?? .lb
    }

    /// The date the sheet is currently acting on: the picker value when
    /// editable, otherwise the fixed `date`.
    private var effectiveDate: Date {
        editableDate ? selectedDate : date
    }

    /// The existing entry for the effective date, if one exists.
    private var existing: WeightEntry? { lookupEntry(effectiveDate) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    inputCard
                    actionRow
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle(existing == nil ? "Add weight" : "Edit weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.primary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .onAppear {
            selectedDate = date
            syncInputToExistingEntry()
        }
        .onChange(of: selectedDate) { _, _ in
            syncInputToExistingEntry()
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editableDate {
                DatePicker(
                    "Date",
                    selection: $selectedDate,
                    in: lowerBound ... Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .tint(Theme.CTP.mauve)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.FG.secondary)
            } else {
                Text(effectiveDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8).textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("0.0", text: $input)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.FG.primary)
                    .tint(Theme.CTP.mauve)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(unit.rawValue)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.FG.tertiary)
            }
        }
        .padding(16)
        .ctpCard()
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    guard let value = parsed else { return }
                    await onSave(effectiveDate, value, unit)
                    dismiss()
                }
            } label: {
                Text("Save")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.CTP.base)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isValid ? Theme.CTP.mauve : Theme.CTP.mauve.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isValid)

            if existing != nil {
                Button {
                    Task {
                        await onDelete(effectiveDate)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.CTP.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.CTP.red.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Sets the input field from the existing entry for the effective date
    /// (prefill), or clears it when no entry exists yet.
    /// Inputs: none (reads `effectiveDate`, `lookupEntry`, `unit`).
    /// Outputs: none; mutates `input`.
    private func syncInputToExistingEntry() {
        if let entry = lookupEntry(effectiveDate) {
            input = WeightFormatter.entryString(WeightFormatter.fromLb(entry.weightLb, to: unit))
        } else {
            input = ""
        }
    }

    private var parsed: Double? { NumericInput.parseDecimal(input) }

    private var isValid: Bool {
        guard let value = parsed else { return false }
        return value > 0 && value < WeightFormatter.entryLimit
    }
}
