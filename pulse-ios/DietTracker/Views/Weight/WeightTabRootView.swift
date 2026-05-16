import SwiftUI

enum WeightSection: String, CaseIterable, Hashable {
    case log = "Log"
    case trends = "Trends"
}

struct WeightTabRootView: View {
    @State private var section: WeightSection = .log

    var body: some View {
        ZStack(alignment: .top) {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 0) {
                CTPSegmented(selection: $section, options: WeightSection.allCases) { $0.rawValue }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Group {
                    switch section {
                    case .log:    WeightLogView()
                    case .trends: WeightTrendsView()
                    }
                }
            }
        }
        .navigationTitle("Weight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.BG.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

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
