// Pulse/Views/Prep/QuantityEntryView.swift
/// Quantity step of the Prep food picker. Lets the user weigh (pick container →
/// gross reading → net grams) or type a quantity (unit keyed to the food's
/// basis), shows a live macro preview, and returns a built `BatchFoodItem`.
/// A basis-context footer (e.g. "1 serving = 250 g") is shown beneath the
/// quantity section so the field label is always interpretable.
import SwiftUI

/// Sheet for choosing a quantity for one searched food.
struct QuantityEntryView: View {
    /// The food the user picked from search.
    let result: FoodSearchResult
    /// Containers available for weighing / labeling (for tare lookup).
    let containers: [Container]
    /// Called with the assembled batch item when the user confirms.
    let onAdd: (BatchFoodItem) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Quantity entry mode.
    private enum Mode: Hashable { case weigh, type }

    @State private var mode: Mode = .type
    @State private var selectedContainerId: UUID?
    @State private var grossText: String = ""
    @State private var typedText: String = ""

    /// Whether weighing is offered for this food's basis.
    private var canWeigh: Bool { result.nutrition.allowsWeighing }

    /// The selected container, if any.
    private var container: Container? { containers.first { $0.id == selectedContainerId } }

    /// Net grams for weigh mode (gross − tare), or nil if inputs are incomplete.
    private var netGrams: Double? {
        guard let gross = Double(grossText), let tare = container?.tareWeightG else { return nil }
        return max(0, gross - tare)
    }

    /// Live macro preview for the current inputs, or nil when not computable.
    private var previewMacros: MacroTotals? {
        switch mode {
        case .weigh:
            guard let net = netGrams else { return nil }
            return result.nutrition.macros(netGrams: net)
        case .type:
            guard let v = Double(typedText) else { return nil }
            return result.nutrition.macros(typedValue: v, unit: result.nutrition.typeUnit)
        }
    }

    /// Label for the typed-quantity field based on the food's basis.
    private var typeUnitLabel: String {
        switch result.nutrition.typeUnit {
        case .grams: return "Grams"
        case .servings: return "Servings"
        case .units: return "Units"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                Form {
                    if canWeigh {
                        Section {
                            Picker("Mode", selection: $mode) {
                                Text("Weigh").tag(Mode.weigh)
                                Text("Type").tag(Mode.type)
                            }
                            .pickerStyle(.segmented)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }

                    if mode == .weigh && canWeigh {
                        Section {
                            containerMenu(required: true)
                            TextField("Gross reading (g)", text: $grossText)
                                .keyboardType(.decimalPad)
                                .foregroundStyle(Theme.FG.primary)
                            if let net = netGrams {
                                Text("Net: \(Int(net)) g")
                                    .foregroundStyle(Theme.FG.secondary)
                            }
                        } header: {
                            Text("Weigh")
                        } footer: {
                            Text(result.nutrition.basisContextLine)
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .listRowBackground(Theme.BG.tertiary)
                    } else {
                        Section {
                            TextField(typeUnitLabel, text: $typedText)
                                .keyboardType(.decimalPad)
                                .foregroundStyle(Theme.FG.primary)
                            containerMenu(required: false)
                        } header: {
                            Text("Quantity")
                        } footer: {
                            Text(result.nutrition.basisContextLine)
                                .foregroundStyle(Theme.FG.tertiary)
                        }
                        .listRowBackground(Theme.BG.tertiary)
                    }

                    Section("Preview") {
                        if let m = previewMacros {
                            Text(m.compactLine)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Theme.CTP.mauve)
                        } else {
                            Text("Enter a quantity")
                                .foregroundStyle(Theme.FG.secondary)
                        }
                    }
                    .listRowBackground(Theme.BG.tertiary)
                }
                .scrollContentBackground(.hidden)
                .tint(Theme.CTP.mauve)
            }
            .navigationTitle(result.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addItem() }
                        .foregroundStyle(Theme.CTP.mauve)
                        .disabled(previewMacros == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.FG.secondary)
                }
            }
            .onAppear { if canWeigh { mode = .weigh } }
        }
        .preferredColorScheme(.dark)
    }

    /// A menu for choosing the container (tare source, or optional label).
    /// Inputs:
    ///   - required: when true, no "None" option is offered (weigh mode needs a tare).
    /// Outputs: a labeled `Menu` of the available containers.
    @ViewBuilder
    private func containerMenu(required: Bool) -> some View {
        Menu {
            if !required {
                Button("None") { selectedContainerId = nil }
            }
            ForEach(containers) { c in
                Button("\(c.name) (\(Int(c.tareWeightG.rounded())) g)") { selectedContainerId = c.id }
            }
        } label: {
            HStack {
                Text(required ? "Container" : "Container (optional)")
                    .foregroundStyle(Theme.FG.primary)
                Spacer()
                Text(container?.name ?? (required ? "Select" : "None"))
                    .foregroundStyle(Theme.FG.secondary)
            }
        }
    }

    /// Builds and emits the `BatchFoodItem`, then dismisses.
    private func addItem() {
        guard let macros = previewMacros else { return }
        let quantity: BatchQuantity = mode == .weigh
            ? .weighed(grossG: Double(grossText) ?? 0)
            : .typed(value: Double(typedText) ?? 0, unit: result.nutrition.typeUnit)
        let item = BatchFoodItem(
            id: UUID(), displayName: result.displayName, usdaFdcId: result.usdaFdcId,
            usdaDescription: result.usdaDescription, customFoodId: result.customFoodId,
            nutrition: result.nutrition, quantity: quantity, containerId: selectedContainerId, macros: macros)
        onAdd(item)
        dismiss()
    }
}
