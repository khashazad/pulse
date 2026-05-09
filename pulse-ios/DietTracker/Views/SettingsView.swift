import SwiftUI

struct SettingsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        section(header: "Account") {
                            row(label: "Email") {
                                Text(auth.email ?? "—")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.CTP.mauve)
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Server") {
                                Text(Constants.baseURL.absoluteString)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.FG.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Button {
                            Task { @MainActor in
                                await auth.signOut()
                                dismiss()
                            }
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.CTP.peach)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.horizontal, 16)

                        section(header: "Theme") {
                            row(label: "Palette") {
                                HStack(spacing: 8) {
                                    HStack(spacing: 3) {
                                        ForEach([Theme.CTP.blue, Theme.CTP.mauve, Theme.CTP.pink, Theme.CTP.peach, Theme.CTP.green], id: \.self.description) { color in
                                            Circle().fill(color).frame(width: 10, height: 10)
                                        }
                                    }
                                    Text("Macchiato")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.FG.primary)
                                }
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Appearance") {
                                Text("Always dark")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.FG.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.BG.secondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.CTP.mauve)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<Content: View>(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.FG.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content() }
                .ctpCard()
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.FG.tertiary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func row<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.FG.primary)
                .frame(minWidth: 70, alignment: .leading)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    SettingsView()
        .environment(AuthSession(baseURL: URL(string: "https://example.test")!))
}
