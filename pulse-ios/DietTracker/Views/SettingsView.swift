import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// When true, the sheet cannot be dismissed without valid config.
    let requireConfig: Bool

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://your-server.up.railway.app", text: $settings.baseURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if settings.keychainWriteFailed {
                        Label("Couldn't save API key to Keychain.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("User: \(Constants.userKey)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(requireConfig && !settings.isConfigured)
                }
            }
            .interactiveDismissDisabled(requireConfig && !settings.isConfigured)
        }
    }
}

#Preview {
    SettingsView(requireConfig: false)
        .environment(AppSettings())
}
