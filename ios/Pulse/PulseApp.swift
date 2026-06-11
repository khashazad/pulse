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

    /// Constructs the shared stores and wires session-clear to reset every
    /// per-user store (targets, progress photos, photo tags) so no data or
    /// retry loop from the prior session survives sign-out / 401 handling.
    /// - Returns: Nothing; initializes the app's shared state.
    init() {
        let authInit = AuthSession(baseURL: Constants.baseURL)
        let targets = UserTargetsStore()
        let photos = ProgressPhotoStore(auth: authInit)
        let photoTags = ProgressPhotoTagStore(auth: authInit)
        authInit.onSessionCleared = { [weak targets, weak photos, weak photoTags] in
            targets?.clear()
            // The photo stores are main-actor isolated; hop before clearing.
            Task { @MainActor in
                photos?.clear()
                photoTags?.clear()
            }
        }
        _auth = State(initialValue: authInit)
        _photoStore = State(initialValue: photos)
        _photoTagStore = State(initialValue: photoTags)
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
