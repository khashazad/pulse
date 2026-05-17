import SwiftUI

@main
struct DietTrackerApp: App {
    @State private var settings = AppSettings()
    @State private var auth: AuthSession
    @State private var photoStore: ProgressPhotoStore
    @State private var targetsStore: UserTargetsStore

    init() {
        let authInit = AuthSession(baseURL: Constants.baseURL)
        let targets = UserTargetsStore()
        authInit.onSessionCleared = { [weak targets] in targets?.clear() }
        _auth = State(initialValue: authInit)
        _photoStore = State(initialValue: ProgressPhotoStore(auth: authInit))
        _targetsStore = State(initialValue: targets)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(auth)
                .environment(photoStore)
                .environment(targetsStore)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
