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
                .font(DesignTokens.TypeScale.subtitleEmphasis)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .padding(.leading, DesignTokens.Space.sm)
        .padding(.trailing, DesignTokens.Space.m)
        .frame(height: Self.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.onyx.opacity(isSelected ? 1 : 0)))
    }
}
