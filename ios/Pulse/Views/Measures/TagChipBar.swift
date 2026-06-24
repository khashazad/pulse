/// Horizontal, single-select chip strip of progress-photo tags. Shared by the
/// gallery (browse a tag) and the pair comparison (switch the compared tag). A
/// horizontal `ScrollView` is safe to nest inside the vertical content scroll —
/// UIKit disambiguates the two by direction.
import SwiftUI

/// A horizontally scrolling row of selectable tag chips.
struct TagChipBar: View {
    /// Tags to show, in display order.
    let tags: [ProgressPhotoTag]
    /// Id of the currently selected tag, highlighted with the mauve fill.
    let selectedId: UUID?
    /// Invoked with the tapped tag.
    let onSelect: (ProgressPhotoTag) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    chip(tag, selected: tag.id == selectedId)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// One tag chip.
    /// - Parameters:
    ///   - tag: the tag the chip represents.
    ///   - selected: whether this chip is the active selection.
    /// - Returns: the styled, tappable chip.
    private func chip(_ tag: ProgressPhotoTag, selected: Bool) -> some View {
        Button { onSelect(tag) } label: {
            Text(tag.name)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Theme.CTP.mauve : Theme.BG.secondary, in: Capsule())
                .foregroundStyle(selected ? Theme.CTP.base : Theme.FG.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
