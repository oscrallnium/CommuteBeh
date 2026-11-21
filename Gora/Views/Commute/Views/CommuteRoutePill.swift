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
    /// Widest a pill text grows before it truncates.
    static let textMaxWidth: CGFloat = 120

    let originText: String
    let destinationText: String
    /// True while the panel's moving layer draws the markers and texts in their place.
    let hidesMovingContent: Bool
    @Binding var frames: [String: CGRect]

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            marker(.origin, id: SearchGeometryID.originDot)

            pillText(originText, id: SearchGeometryID.originText)

            Image(systemName: Symbol.arrowRight)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            marker(.destination, id: SearchGeometryID.destinationDot)

            pillText(destinationText, id: SearchGeometryID.destinationText)
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

    private func pillText(_ text: String, id: String) -> some View {
        Text(text)
            .typeScale(.rowTitle)
            .lineLimit(1)
            .frame(maxWidth: Self.textMaxWidth, alignment: .leading)
            .reportsFrame(id, in: CoordinateSpaces.pill, to: $frames)
            .snapsOpacity(!hidesMovingContent)
    }
}

private enum CoordinateSpaces {
    static let pill = "route-pill"
}

private enum Symbol {
    static let arrowRight = "arrow.right"
}
