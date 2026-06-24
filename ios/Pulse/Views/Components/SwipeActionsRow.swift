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
    private let surfaceTint: Color?
    private let content: Content

    /// Width of each revealed action button (the tap target; the visible pill is
    /// a smaller circle centered within it).
    private static var buttonWidth: CGFloat { 64 }
    /// Diameter of the floating circular icon pill inside each action button.
    private static var pillDiameter: CGFloat { 40 }
    /// Current horizontal offset of the row content (negative = revealed).
    @State private var offset: CGFloat = 0
    /// Offset captured at gesture start so drags are cumulative.
    @State private var startOffset: CGFloat = 0

    /// Creates a swipeable row.
    /// - Parameters:
    ///   - actions: Trailing actions revealed on swipe (leftmost shown first).
    ///   - surfaceTint: Translucent wash of the enclosing `ctpCard`, so the
    ///     content's opaque backing (which hides the action buttons sliding
    ///     behind it) matches the card surface exactly. Pass the SAME tint the
    ///     card uses; `nil` (the default) backs with the plain card fill.
    ///   - content: The row content.
    init(actions: [SwipeAction], surfaceTint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.surfaceTint = surfaceTint
        self.content = content()
    }

    /// Opaque backing that reproduces the enclosing `ctpCard` surface (base fill
    /// plus its translucent tint), so the sliding content reads as part of the
    /// card rather than a darker inset strip.
    /// - Returns: The composited surface view drawn behind the row content.
    private var rowSurface: some View {
        Theme.BG.tertiary.overlay(surfaceTint ?? Color.clear)
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
                        // Floating pill: the SF Symbol in the action's color on a
                        // soft same-hue circle, sitting on the card surface — no
                        // full-height color slab. The wider frame is the tap target.
                        Image(systemName: action.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(action.tint)
                            .frame(width: Self.pillDiameter, height: Self.pillDiameter)
                            .background(Circle().fill(action.tint.opacity(0.20)))
                            .frame(width: Self.buttonWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.label)
                }
            }
            .opacity(offset < 0 ? 1 : 0)

            content
                .background(rowSurface)
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
