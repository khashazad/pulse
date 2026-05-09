import SwiftUI
import UIKit

struct LoginView: View {
    @Environment(AuthSession.self) private var auth

    var body: some View {
        ZStack {
            Theme.BG.primary.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Diet Tracker")
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

    private var isSigningIn: Bool {
        if case .signingIn = auth.state { return true } else { return false }
    }

    private func signIn() {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene),
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }
        Task { @MainActor in
            await auth.signInWithGoogle(presentationAnchor: window)
        }
    }
}
