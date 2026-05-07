import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let requireConfig: Bool

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ZStack {
                Theme.BG.secondary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        section(header: "Server",
                                footer: "Connect to a Diet Tracker server. Your API key is sent as a bearer token.") {
                            VStack(spacing: 0) {
                                textField(
                                    placeholder: "https://your-server.up.railway.app",
                                    text: $settings.baseURLString,
                                    isMono: true
                                )
                                .keyboardType(.URL)
                                Rectangle().fill(Theme.separator).frame(height: 0.5)
                                textField(
                                    placeholder: "API key",
                                    text: $settings.apiKey,
                                    isMono: true
                                )
                            }
                            if settings.keychainWriteFailed {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Couldn't save API key to Keychain.")
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.CTP.peach)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                            }
                        }

                        section(header: "Account") {
                            row(label: "User") {
                                Text(Constants.userKey)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.CTP.mauve)
                            }
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                            row(label: "Status") {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(settings.isConfigured ? Theme.CTP.green : Theme.CTP.peach)
                                        .frame(width: 6, height: 6)
                                        .shadow(
                                            color: (settings.isConfigured ? Theme.CTP.green : Theme.CTP.peach).opacity(0.8),
                                            radius: 4
                                        )
                                    Text(settings.isConfigured ? "Configured" : "Not configured")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(settings.isConfigured ? Theme.CTP.green : Theme.CTP.peach)
                                }
                            }
                        }

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
                        .disabled(requireConfig && !settings.isConfigured)
                }
            }
            .interactiveDismissDisabled(requireConfig && !settings.isConfigured)
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

    private func textField(placeholder: String, text: Binding<String>, isMono: Bool) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.FG.tertiary))
            .font(.system(size: 15, design: isMono ? .monospaced : .default))
            .foregroundStyle(Theme.FG.primary)
            .tint(Theme.CTP.mauve)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
    SettingsView(requireConfig: false)
        .environment(AppSettings())
}
