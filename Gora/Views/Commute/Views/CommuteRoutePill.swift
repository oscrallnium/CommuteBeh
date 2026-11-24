//
//  CommuteRoutePill.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import SwiftUI

/// The collapsed search content: origin, arrow, destination. It draws no surface;
/// `CommuteSearchPanel` supplies the glass behind it.
struct CommuteRoutePill: View {
    /// Pill height. The panel uses half of it as the surface corner radius, so the surface is a capsule.
    static let height: CGFloat = 44
    /// Widest a pill text grows, whatever width the panel offers.
    static let textMaxWidth: CGFloat = 120

    /// The widest each pill text grows before it truncates with an ellipsis.
    struct TextWidths: Equatable {
        let origin: CGFloat
        let destination: CGFloat

        static let capped = TextWidths(origin: textMaxWidth, destination: textMaxWidth)
    }

    let originText: String
    let destinationText: String
    let textWidths: TextWidths
    /// True while the panel's moving layer draws the markers and texts in their place.
    let hidesMovingContent: Bool
    @Binding var frames: [String: CGRect]

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            marker(.origin, id: SearchGeometryID.originDot)

            pillText(originText, maxWidth: textWidths.origin, id: SearchGeometryID.originText)

            Image(systemName: Symbol.arrowRight)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            marker(.destination, id: SearchGeometryID.destinationDot)

            pillText(destinationText, maxWidth: textWidths.destination, id: SearchGeometryID.destinationText)
        }
        .padding(.horizontal, DesignTokens.Space.l)
        .frame(height: Self.height)
        .coordinateSpace(name: CoordinateSpaces.pill)
    }

    private func marker(_ kind: SearchMarker.Kind, id: String) -> some View {
        SearchMarker(kind: kind)
            .reportsFrame(id, in: CoordinateSpaces.pill, to: $frames)
            .snapsOpacity(!hidesMovingContent)
    }

    /// The pill text on one line, as the pill draws it before any width limit.
    static func label(_ text: String) -> some View {
        Text(text)
            .typeScale(.rowTitle)
            .lineLimit(1)
    }

    /// Splits the width left for text between origin and destination. Each text gets at most half.
    /// A text that needs less than half leaves the rest to the other. Both stay under `textMaxWidth`.
    static func textWidths(
        availablePillWidth: CGFloat,
        originIdeal: CGFloat,
        destinationIdeal: CGFloat
    ) -> TextWidths {
        guard availablePillWidth > 0 else { return .capped }
        let budget = max(availablePillWidth - Layout.fixedWidth, 0)
        let half = budget / 2
        let origin = min(originIdeal, textMaxWidth)
        let destination = min(destinationIdeal, textMaxWidth)
        let widths: (CGFloat, CGFloat) = if origin <= half {
            (origin, min(destination, budget - origin))
        } else if destination <= half {
            (min(origin, budget - destination), destination)
        } else {
            (half, half)
        }
        return TextWidths(origin: widths.0.rounded(.down), destination: widths.1.rounded(.down))
    }

    private func pillText(_ text: String, maxWidth: CGFloat, id: String) -> some View {
        Self.label(text)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .reportsFrame(id, in: CoordinateSpaces.pill, to: $frames)
            .snapsOpacity(!hidesMovingContent)
    }
}

private enum Layout {
    /// The two markers, 11 pt and 10 pt wide.
    static let markersWidth: CGFloat = 21
    /// The arrow symbol, with a margin for font rounding.
    static let arrowWidth: CGFloat = 14
    /// Width of everything but the texts: side padding, markers, arrow, and the four gaps.
    static let fixedWidth: CGFloat = 2 * DesignTokens.Space.l + markersWidth + arrowWidth + 4 * DesignTokens.Space.xs
}

private enum CoordinateSpaces {
    static let pill = "route-pill"
}

private enum Symbol {
    static let arrowRight = "arrow.right"
}
