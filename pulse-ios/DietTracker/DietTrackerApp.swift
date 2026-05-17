import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()
    @State private var auth: AuthSession
    @State private var photoStore: ProgressPhotoStore

    init() {
        let authInit = AuthSession(baseURL: Constants.baseURL)
        _auth = State(initialValue: authInit)
        _photoStore = State(initialValue: ProgressPhotoStore(auth: authInit))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(auth)
                .environment(photoStore)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
