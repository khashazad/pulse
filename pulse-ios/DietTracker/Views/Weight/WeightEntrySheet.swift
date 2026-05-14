import SwiftUI

struct WeightEntrySheet: View {
    let date: Date
    let existing: WeightEntry?
    let onSave: (Double, WeightUnit) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""
    @State private var unit: WeightUnit = .lb
    @AppStorage(WeightUnit.displayPreferenceKey)
    private var displayUnitRaw: String = WeightUnit.defaultDisplayUnit.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.primary.ignoresSafeArea()
                VStack(spacing: 24) {
                    Text(date.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.FG.secondary)

                    TextField("Weight", text: $input)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.FG.primary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.BG.secondary))

                    Picker("Unit", selection: $unit) {
                        Text("lb").tag(WeightUnit.lb)
                        Text("kg").tag(WeightUnit.kg)
                    }
                    .pickerStyle(.segmented)

                    Spacer()

                    Button {
                        Task {
                            guard let value = parsed else { return }
                            await onSave(value, unit)
                            dismiss()
                        }
                    } label: {
                        Text("Save")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.CTP.mauve))
                            .foregroundStyle(.black)
                    }
                    .disabled(!isValid)

                    if let onDelete {
                        Button(role: .destructive) {
                            Task {
                                await onDelete()
                                dismiss()
                            }
                        } label: {
                            Text("Delete weigh-in")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.CTP.peach)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(existing == nil ? "Add weight" : "Edit weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .onAppear {
            if let existing {
                input = String(format: "%.1f",
                    WeightFormatter.fromLb(existing.weightLb, to: existing.sourceUnit))
                unit = existing.sourceUnit
            } else if let pref = WeightUnit(rawValue: displayUnitRaw) {
                unit = pref
            }
        }
    }

    private var parsed: Double? { Double(input.replacingOccurrences(of: ",", with: ".")) }

    private var isValid: Bool {
        guard let value = parsed else { return false }
        return value > 0 && value < 2000
    }
}
