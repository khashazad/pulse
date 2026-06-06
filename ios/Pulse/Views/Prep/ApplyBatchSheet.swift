// Pulse/Views/Prep/ApplyBatchSheet.swift
/// Sheet for applying prep-batch portions to selected days: quick-pick chips
/// for the next week, a multi-date picker for arbitrary days, per-day portion
/// steppers, duplicate/over-allocation warnings, a what-will-be-logged review,
/// and a single atomic submit. Renders `ApplyBatchModel`; owns no business logic.
import SwiftUI

/// Sheet for applying prep-batch portions to one or more selected days as
/// real food entries. Consumed by `PrepView`.
struct ApplyBatchSheet: View {
    /// The backing model; injected fresh by `PrepView` on each presentation.
    let model: ApplyBatchModel
    /// Called with the applied day keys after a successful submit, before dismiss.
    let onApplied: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Tomorrow → +7 inclusive: the quick-pick week.
    /// Computed once at init from `model.calendar` so all day math is calendar-consistent.
    /// Outputs: seven `Date` values at midnight local time, starting tomorrow.
    private let chipDays: [Date]

    /// Creates the sheet and pre-computes the chip days using the model's injected calendar.
    /// Inputs:
    ///   - model: the fresh `ApplyBatchModel` for this presentation.
    ///   - onApplied: callback receiving applied day keys on successful submit.
    /// Outputs: an `ApplyBatchSheet`.
    init(model: ApplyBatchModel, onApplied: @escaping (Set<String>) -> Void) {
        self.model = model
        self.onApplied = onApplied
        let start = model.calendar.startOfDay(for: Date())
        self.chipDays = (1...7).compactMap { model.calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Renders the full apply-to-days sheet: quick-pick chips, multi-date calendar,
    /// per-day allocation steppers with duplicate warnings, a review list, and a
    /// submit toolbar button.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    chipSection
                    calendarSection
                    if !model.selections.isEmpty {
                        allocationHeader
                        reviewSection
                    }
                    if case .failed(let err) = model.submitState {
                        errorBanner(err)
                    }
                }
                .padding(16)
            }
            .background(Theme.BG.primary)
            .navigationTitle("Apply to days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.FG.secondary)
                }
                ToolbarItem(placement: .confirmationAction) { submitButton }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    /// Quick-pick chips for tomorrow through +7.
    @ViewBuilder
    private var chipSection: some View {
        SectionCard(header: "Next week") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chipDays, id: \.self) { day in
                        chip(for: day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// One day chip; selected state fills with mauve, conflict shows a badge.
    /// Inputs:
    ///   - day: the chip's day (midnight local).
    /// Outputs: a styled button `View`.
    @ViewBuilder
    private func chip(for day: Date) -> some View {
        let key = DateOnly.formatter.string(from: day)
        let selected = model.isSelected(day)
        let conflicted = model.appliedDayKeys.contains(key)
        Button {
            model.toggle(day)
        } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 11, weight: .medium))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                if conflicted {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(selected ? Theme.BG.primary : Theme.FG.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.CTP.mauve : Theme.BG.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Calendar for arbitrary dates (today included), synced with the model.
    @ViewBuilder
    private var calendarSection: some View {
        SectionCard(header: "Other days") {
            MultiDatePicker("Days", selection: multiDateBinding)
                .tint(Theme.CTP.mauve)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    /// Two-way bridge between `MultiDatePicker`'s `Set<DateComponents>` and the
    /// model's selection list. Only `.year`, `.month`, `.day` are extracted in the
    /// getter — including `.calendar` or `.era` breaks `Set` membership equality
    /// with what `MultiDatePicker` produces, causing spurious double-toggles.
    /// Outputs: a `Binding<Set<DateComponents>>` that stays in sync with `model.selections`.
    private var multiDateBinding: Binding<Set<DateComponents>> {
        Binding(
            get: {
                Set(model.selections.map {
                    model.calendar.dateComponents([.year, .month, .day], from: $0.date)
                })
            },
            set: { components in
                let days = Set(
                    components
                        .compactMap { model.calendar.date(from: $0) }
                        .map { model.calendar.startOfDay(for: $0) }
                )
                let current = Set(model.selections.map(\.date))
                for added in days.subtracting(current) { model.toggle(added) }
                for removed in current.subtracting(days) { model.toggle(removed) }
            }
        )
    }

    /// "X of N portions allocated" line, amber when over-allocated.
    @ViewBuilder
    private var allocationHeader: some View {
        HStack(spacing: 6) {
            if model.isOverAllocated {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
            }
            Text("\(model.allocatedPortions) of \(model.portions) portions allocated")
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(model.isOverAllocated ? Theme.CTP.yellow : Theme.FG.secondary)
    }

    /// Per-day review: stepper, duplicate flag, each food's share, day total.
    @ViewBuilder
    private var reviewSection: some View {
        SectionCard(header: "Will be logged") {
            ForEach(model.selections) { sel in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(sel.date.formatted(.dateTime.weekday(.wide).month().day()))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { sel.count },
                                set: { model.setCount($0, forDay: sel.dayKey) }
                            ),
                            in: 1...99
                        ) {
                            Text("\(sel.count)x")
                                .font(.system(size: 13, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.FG.primary)
                        }
                        .tint(Theme.CTP.mauve)
                        .fixedSize()
                    }
                    if model.appliedDayKeys.contains(sel.dayKey) {
                        Text("Already applied to this day — applying again will duplicate")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.CTP.yellow)
                    }
                    ForEach(model.items) { item in
                        let m = item.macros.scaled(count: sel.count, portions: model.portions)
                        HStack {
                            Text(item.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.FG.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(m.calories) kcal")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.FG.secondary)
                        }
                    }
                    HStack {
                        Text("Day total")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        Spacer()
                        Text(model.dayTotal(for: sel).compactLine)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle()
                    .fill(Theme.BG.tertiary)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }

    /// Submit toolbar button: disabled with no selection, spinner while submitting.
    @ViewBuilder
    private var submitButton: some View {
        if model.submitState == .submitting {
            ProgressView().tint(Theme.CTP.mauve)
        } else {
            Button("Apply") {
                Task {
                    if let applied = await model.submit() {
                        onApplied(applied)
                        dismiss()
                    }
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(model.selections.isEmpty ? Theme.FG.tertiary : Theme.CTP.mauve)
            .disabled(model.selections.isEmpty)
        }
    }

    /// Inline error line for a failed submit; nothing was logged (atomic batch).
    /// Follows the app-wide failed-state convention (`Label` + triangle glyph +
    /// `userMessage`, as in `CopyEntriesSheet` and the tab views).
    /// Inputs:
    ///   - error: the failure to surface.
    /// Outputs: a styled error `View`.
    @ViewBuilder
    private func errorBanner(_ error: PulseError) -> some View {
        Label("Nothing was logged: \(error.userMessage)", systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(Theme.CTP.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}
