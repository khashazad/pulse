import SwiftUI

struct WeightEntrySheet: View {
    let date: Date
    let existing: WeightEntry?
    let onSave: (Double, WeightUnit) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    private var unit: WeightUnit {
        WeightUnit(rawValue: displayUnitRaw) ?? .lb
    }

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
            if let existing {
                input = String(format: "%.1f", WeightFormatter.fromLb(existing.weightLb, to: unit))
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.FG.secondary)

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
                    await onSave(value, unit)
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

            if let onDelete {
                Button {
                    Task {
                        await onDelete()
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

    private var parsed: Double? { Double(input.replacingOccurrences(of: ",", with: ".")) }

    private var isValid: Bool {
        guard let value = parsed else { return false }
        return value > 0 && value < 2000
    }
}
