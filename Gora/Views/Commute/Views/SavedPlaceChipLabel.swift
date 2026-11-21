//
//  SavedPlaceChipLabel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// The content of one chip in the saved-places row. The row and the drag overlay both draw it,
/// so a dragged chip matches the chip it leaves behind.
struct SavedPlaceChipLabel: View {
    let icon: String
    let iconSize: CGFloat
    let title: String
    let isSelected: Bool
    /// Icon and title color while the chip is not selected.
    var restingColor: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 40
    /// Widest title, about 12 characters at the chip font. A longer title ends in an ellipsis.
    static let maxTitleWidth: CGFloat = 90

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            Text(title)
                .typeScale(.subtitleEmphasis)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
        }
        .foregroundStyle(isSelected ? Color.white : restingColor)
        .padding(.leading, DesignTokens.Space.sm)
        .padding(.trailing, DesignTokens.Space.m)
        .frame(height: Self.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(selectionFill)
        .animation(selectionAnimation, value: isSelected)
    }

    /// Teal capsule of a selected chip. It grows from a smaller scale as it appears.
    private var selectionFill: some View {
        Capsule()
            .fill(Color.selectionRing)
            .opacity(isSelected ? 1 : 0)
            .scaleEffect(isSelected || reduceMotion ? 1 : Motion.hiddenFillScale)
    }

    /// A short spring for the selection change. Reduce Motion keeps a plain fade.
    private var selectionAnimation: Animation {
        reduceMotion
            ? DesignTokens.Motion.disclose
            : .spring(response: Motion.springResponse, dampingFraction: Motion.springDamping)
    }
}

private enum Motion {
    static let hiddenFillScale: CGFloat = 0.85
    static let springResponse: Double = 0.3
    static let springDamping: Double = 0.7
}
