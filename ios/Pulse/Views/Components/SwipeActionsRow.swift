/// A reusable swipe-to-reveal-actions row for non-`List` content. The day view
/// is a `ScrollView` of bespoke `ctpCard`s, so SwiftUI's `.swipeActions`
/// (List-only) is unavailable; this wraps any row content and reveals trailing
/// action buttons on a leftward drag. Every action requires an explicit tap —
/// there is no full-swipe auto-trigger.
///
/// Implemented as a nested **horizontal** `ScrollView` (one per row) rather than
/// a hand-rolled `DragGesture`: a custom drag gesture attached to content inside
/// a vertical `ScrollView` swallows the touch and blocks vertical scrolling over
/// the row body (even via `simultaneousGesture`). Nested scroll views instead let
/// UIKit disambiguate by direction — vertical pans scroll the list, horizontal
/// pans reveal the actions — so the two never conflict.
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

/// Wraps `content` and reveals `actions` as trailing buttons on a left swipe.
struct SwipeActionsRow<Content: View>: View {
    private let actions: [SwipeAction]
    private let surfaceTint: Color?
    private let content: Content

    /// Width of each revealed action button (the tap target; the visible pill is
    /// a smaller circle centered within it).
    private static var buttonWidth: CGFloat { 64 }
    /// Diameter of the floating circular icon pill inside each action button.
    private static var pillDiameter: CGFloat { 40 }
    /// Stable id for the content cell, used to scroll the row closed after a tap.
    private static var contentID: String { "content" }

    /// Creates a swipeable row.
    /// - Parameters:
    ///   - actions: Trailing actions revealed on swipe (leftmost shown first).
    ///   - surfaceTint: Translucent wash of the enclosing `ctpCard`, so the row
    ///     content's opaque backing matches the card surface exactly. Pass the
    ///     SAME tint the card uses; `nil` (the default) backs with the plain fill.
    ///   - content: The row content.
    init(actions: [SwipeAction], surfaceTint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.surfaceTint = surfaceTint
        self.content = content()
    }

    /// Total width the open row reveals.
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.buttonWidth }

    /// Opaque backing that reproduces the enclosing `ctpCard` surface (base fill
    /// plus its translucent tint), so the row content reads as part of the card.
    /// - Returns: The composited surface view drawn behind the row content.
    private var rowSurface: some View {
        Theme.BG.tertiary.overlay(surfaceTint ?? Color.clear)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    content
                        .background(rowSurface)
                        .containerRelativeFrame(.horizontal)
                        .id(Self.contentID)
                    actionButtons(proxy)
                        .frame(width: revealWidth)
                        .frame(maxHeight: .infinity)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(SwipeSnapBehavior(revealWidth: revealWidth))
        }
    }

    /// The revealed trailing actions: a floating same-color icon pill per action,
    /// laid out left-to-right. Tapping one scrolls the row closed, then runs the
    /// handler.
    /// - Parameter proxy: Scroll proxy used to animate the row closed on tap.
    /// - Returns: The composed actions strip.
    private func actionButtons(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.contentID, anchor: .leading)
                    }
                    action.handler()
                } label: {
                    // Floating pill: the SF Symbol in the action's color on a soft
                    // same-hue circle, sitting on the card surface.
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
    }
}

/// Snaps the row's horizontal scroll to fully closed (0) or fully open
/// (`revealWidth`) based on where a drag/fling would land, so the row never rests
/// half-open. Replaces a `DragGesture`'s `onEnded` snap logic.
private struct SwipeSnapBehavior: ScrollTargetBehavior {
    /// The open resting offset (sum of the action-button widths).
    let revealWidth: CGFloat

    /// Rounds the proposed landing offset to the nearer of closed/open.
    /// - Parameters:
    ///   - target: The proposed scroll target; its `rect.origin.x` is rewritten.
    ///   - context: Scroll context (unused).
    /// - Returns: Nothing; mutates `target` in place.
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = target.rect.minX > revealWidth / 2 ? revealWidth : 0
    }
}
