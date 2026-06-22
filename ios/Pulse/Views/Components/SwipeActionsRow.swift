/// A reusable swipe-to-reveal-actions row for non-`List` content. The day view
/// is a `ScrollView` of bespoke `ctpCard`s, so SwiftUI's `.swipeActions`
/// (List-only) is unavailable; this wraps any row content and reveals trailing
/// action buttons on a leftward drag. Every action requires an explicit tap —
/// there is no full-swipe auto-trigger.
import SwiftUI

/// One trailing action shown when a `SwipeActionsRow` is open.
struct SwipeAction: Identifiable {
    /// Visual/semantic weight of an action.
    enum Role {
        case normal
        case destructive
    }

    let id = UUID()
    let label: String
    let systemImage: String
    let tint: Color
    let role: Role
    let handler: () -> Void

    /// Creates a swipe action.
    /// - Parameters:
    ///   - label: Accessible/visible label (e.g. "Delete").
    ///   - systemImage: SF Symbol name shown above the label.
    ///   - tint: Background tint of the action button.
    ///   - role: `.destructive` for deletes, `.normal` otherwise.
    ///   - handler: Invoked when the user taps the revealed button.
    init(label: String, systemImage: String, tint: Color, role: Role = .normal, handler: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.handler = handler
    }
}

/// Wraps `content` and reveals `actions` as trailing buttons on a left drag.
struct SwipeActionsRow<Content: View>: View {
    private let actions: [SwipeAction]
    private let content: Content

    /// Width of each revealed action button.
    private static var buttonWidth: CGFloat { 72 }
    /// Current horizontal offset of the row content (negative = revealed).
    @State private var offset: CGFloat = 0
    /// Offset captured at gesture start so drags are cumulative.
    @State private var startOffset: CGFloat = 0

    /// Creates a swipeable row.
    /// - Parameters:
    ///   - actions: Trailing actions revealed on swipe (leftmost shown first).
    ///   - content: The row content.
    init(actions: [SwipeAction], @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.content = content()
    }

    /// Total width the open row reveals.
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.buttonWidth }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        close()
                        action.handler()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                            Text(action.label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.FG.primary)
                        .frame(width: Self.buttonWidth)
                        .frame(maxHeight: .infinity)
                        .background(action.tint.opacity(action.role == .destructive ? 0.9 : 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(offset < 0 ? 1 : 0)

            content
                .background(Theme.BG.primary)
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let proposed = startOffset + value.translation.width
                            offset = min(0, max(-revealWidth, proposed))
                        }
                        .onEnded { _ in
                            let open = offset < -revealWidth / 2
                            let destination: CGFloat = open ? -revealWidth : 0
                            withAnimation(.easeOut(duration: 0.2)) { offset = destination }
                            startOffset = destination
                        }
                )
        }
        .clipped()
    }

    /// Animates the row closed and resets the drag baseline.
    /// - Returns: Nothing.
    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        startOffset = 0
    }
}
