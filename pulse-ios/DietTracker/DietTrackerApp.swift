import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()
    @State private var auth = AuthSession(baseURL: Constants.baseURL)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(auth)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
