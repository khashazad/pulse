/// Root container for the Measures tab.
///
/// Defines the `MeasureSection` segmented-control enum (Log / Photos / Trends),
/// hosts `MeasuresTabRootView` which switches between the three sub-views, and
/// provides the reusable `CTPSegmented` Catppuccin-themed segmented control
/// used both here and in `WeightTrendsView`.
import SwiftUI

/// Top-level segments displayed in the Measures tab's segmented control.
enum MeasureSection: String, CaseIterable, Hashable {
    case log = "Log"
    case photos = "Photos"
    case trends = "Trends"
}

/// Root view that owns the Measures tab section state and renders the active sub-view.
struct MeasuresTabRootView: View {
    @State private var section: MeasureSection = .log

    var body: some View {
        ZStack(alignment: .top) {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                CTPSegmented(selection: $section, options: MeasureSection.allCases) { $0.rawValue }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Group {
                    switch section {
                    case .log:    WeightLogView()
                    case .photos: ProgressPhotosView()
                    case .trends: WeightTrendsView()
                    }
                }
            }
        }
        .navigationTitle("Measures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// Generic Catppuccin-styled segmented control bound to a selection of any `Hashable`.
///
/// Inputs:
/// - selection: two-way binding to the currently selected option.
/// - options: list of available options to render as segments.
/// - label: closure mapping each option to its visible text label.
struct CTPSegmented<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let active = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.FG.primary : Theme.FG.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? Theme.CTP.surface2 : .clear)
                                .shadow(color: active ? .black.opacity(0.2) : .clear, radius: 0, y: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.CTP.surface0.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                )
        )
    }
}
