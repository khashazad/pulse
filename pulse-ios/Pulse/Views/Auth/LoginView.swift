/// Sign-in sheet shown when `AuthSession` is not signed in.
/// Single "Continue with Google" CTA that resolves a UIWindow as the presentation
/// anchor for ASWebAuthenticationSession and forwards to `AuthSession.signInWithGoogle`.
import SwiftUI
import UIKit

/// Login screen with a Google sign-in button and inline error message.
struct LoginView: View {
    @Environment(AuthSession.self) private var auth
    @State private var anchorWindow: UIWindow?

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            WindowReader { window in
                anchorWindow = window
            }
            .frame(width: 0, height: 0)
            VStack(spacing: 24) {
                Spacer()
                Text("Pulse")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.FG.primary)
                Text("Sign in to sync with your server.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.FG.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(action: signIn) {
                    HStack(spacing: 10) {
                        if isSigningIn {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Theme.BG.primary)
                        } else {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Continue with Google")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.BG.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.CTP.mauve)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isSigningIn)
                .padding(.horizontal, 24)

                if case .error(let err) = auth.state {
                    Text(err.userMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.CTP.peach)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer().frame(height: 40)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Whether `AuthSession` is currently in the `.signingIn` state.
    /// Outputs: `true` while the OAuth round-trip is in flight.
    private var isSigningIn: Bool {
        if case .signingIn = auth.state { return true } else { return false }
    }

    /// Starts a Google OAuth flow anchored to the UIWindow that hosts this
    /// LoginView. No-op if the host window has not been resolved yet.
    private func signIn() {
        guard let window = anchorWindow else { return }
        Task { @MainActor in
            await auth.signInWithGoogle(presentationAnchor: window)
        }
    }
}

/// Zero-sized UIViewRepresentable that reports the UIWindow owning the SwiftUI
/// view hierarchy it's installed in. Used to resolve a presentation anchor that
/// matches the rendered scene instead of guessing across `connectedScenes`.
/// On cold launch `makeUIView` can run before SwiftUI inserts the host view
/// into a window; in that case we fall back to the first foreground-active
/// window scene so the Sign-In CTA is reachable on the first tap.
private struct WindowReader: UIViewRepresentable {
    let onResolve: (UIWindow?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { resolve(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { resolve(from: uiView) }
    }

    private func resolve(from view: UIView) {
        if let win = view.window {
            onResolve(win)
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first(where: { $0.activationState == .foregroundActive })
        let win = active?.windows.first(where: \.isKeyWindow)
            ?? active?.windows.first
            ?? scenes.flatMap(\.windows).first
        onResolve(win)
    }
}
