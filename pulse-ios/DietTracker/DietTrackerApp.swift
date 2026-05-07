import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
