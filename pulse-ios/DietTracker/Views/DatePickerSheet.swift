import SwiftUI

struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (Date) -> Void

    @State private var selected: Date = Date()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                VStack {
                    DatePicker(
                        "Pick a date",
                        selection: $selected,
                        in: ...Date(),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .tint(Theme.CTP.mauve)
                    .padding()
                    Spacer()
                }
            }
            .navigationTitle("Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.CTP.mauve)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        onPick(selected)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

#Preview {
    DatePickerSheet { _ in }
}
