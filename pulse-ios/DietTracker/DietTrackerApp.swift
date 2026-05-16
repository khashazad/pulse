import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()
    @State private var auth = AuthSession(baseURL: Constants.baseURL)
    @State private var targetsStore = UserTargetsStore()

    init() {
        let store = targetsStore
        auth.onSessionCleared = { [weak store] in store?.clear() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(auth)
                .environment(targetsStore)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
