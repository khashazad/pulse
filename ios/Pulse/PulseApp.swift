/// App entry point for Pulse.
/// Defines the `@main` `PulseApp` scene, wires up shared `@State` stores
/// (`AuthSession`, `ProgressPhotoStore`, `ProgressPhotoTagStore`,
/// `UserTargetsStore`), and injects them into the SwiftUI environment for the
/// root view tree. Acts as the composition root that ties auth lifecycle to
/// dependent stores.
import SwiftUI

/// Root SwiftUI `App` that owns shared session and store state and presents `RootView`.
@main
struct PulseApp: App {
    @State private var auth: AuthSession
    @State private var photoStore: ProgressPhotoStore
    @State private var photoTagStore: ProgressPhotoTagStore
    @State private var targetsStore: UserTargetsStore

    /// Constructs the shared stores and wires session-clear to targets reset so
    /// per-user state is dropped when the auth session is invalidated.
    init() {
        let authInit = AuthSession(baseURL: Constants.baseURL)
        let targets = UserTargetsStore()
        authInit.onSessionCleared = { [weak targets] in targets?.clear() }
        _auth = State(initialValue: authInit)
        _photoStore = State(initialValue: ProgressPhotoStore(auth: authInit))
        _photoTagStore = State(initialValue: ProgressPhotoTagStore(auth: authInit))
        _targetsStore = State(initialValue: targets)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(photoStore)
                .environment(photoTagStore)
                .environment(targetsStore)
                .preferredColorScheme(.dark)
                .tint(Theme.tint)
        }
    }
}
