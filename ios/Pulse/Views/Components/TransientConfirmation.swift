/// A transient bottom "confirmation chip" overlay: when bound to a non-nil
/// message it slides up, holds briefly, then clears itself. Extracted so the
/// app's save-confirmation chips share one implementation and timing.
import SwiftUI

/// View modifier that overlays a self-dismissing confirmation chip.
private struct TransientConfirmationModifier: ViewModifier {
    @Binding var message: String?
    /// How long the chip stays visible before it auto-dismisses.
    private static let visibleNanoseconds: UInt64 = 1_800_000_000

    /// Overlays the chip on `content`, driving its appearance from `message`.
    /// Inputs:
    ///   - content: the view the chip is layered over.
    /// Outputs: the composed view with the bottom confirmation overlay.
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text("Saved “\(message)”")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.FG.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Theme.BG.secondary)
                                .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5)))
                        .padding(.bottom, Theme.Layout.dockClearance)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(nanoseconds: Self.visibleNanoseconds)
                            withAnimation { self.message = nil }
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    /// Overlays a transient, auto-dismissing confirmation chip.
    /// Inputs:
    ///   - message: binding to the chip's text; set non-nil to show, it clears
    ///     itself after a short delay.
    /// Outputs: a view with the confirmation overlay applied.
    func transientConfirmation(_ message: Binding<String?>) -> some View {
        modifier(TransientConfirmationModifier(message: message))
    }
}
