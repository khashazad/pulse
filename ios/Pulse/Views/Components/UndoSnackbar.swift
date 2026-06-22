/// A bottom "undo" snackbar overlay shown while a delete is in its undo window.
/// Unlike `TransientConfirmation` (self-dismissing chip), this carries an action
/// and stays visible as long as `isPresented` is true — the owning model's undo
/// window controls dismissal by clearing its `pendingDelete`.
import SwiftUI

private struct UndoSnackbarModifier: ViewModifier {
    let isPresented: Bool
    let message: String
    let onUndo: () -> Void

    /// Overlays the snackbar on `content` while `isPresented`.
    /// Inputs:
    ///   - content: the view the snackbar is layered over.
    /// Outputs: the composed view with the bottom undo overlay.
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    HStack(spacing: 14) {
                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.FG.primary)
                        Button("Undo", action: onUndo)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.CTP.mauve)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Theme.BG.secondary)
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5)))
                    .padding(.bottom, Theme.Layout.dockClearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    /// Overlays a bottom undo snackbar while `isPresented`.
    /// Inputs:
    ///   - isPresented: whether the snackbar is shown.
    ///   - message: the snackbar text (e.g. "Entry deleted").
    ///   - onUndo: invoked when the user taps Undo.
    /// Outputs: a view with the undo overlay applied.
    func undoSnackbar(isPresented: Bool, message: String, onUndo: @escaping () -> Void) -> some View {
        modifier(UndoSnackbarModifier(isPresented: isPresented, message: message, onUndo: onUndo))
    }
}
