//
//  SearchMovingLayer.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import SwiftUI

/// Draws both markers and both texts outside the fading panel content, so they stay visible and
/// travel with the surface spring from their card frame to their pill frame.
struct SearchMovingLayer: View {
    let mode: SearchPanelMode
    let originText: String
    let destinationText: String
    let cardFrames: [String: CGRect]
    let pillFrames: [String: CGRect]
    let movesContent: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            movingMarker(.origin, id: SearchGeometryID.originDot)
            movingLabel(originText, id: SearchGeometryID.originText)
            movingMarker(.destination, id: SearchGeometryID.destinationDot)
            movingLabel(destinationText, id: SearchGeometryID.destinationText)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func movingMarker(_ kind: SearchMarker.Kind, id: String) -> some View {
        if let card = cardFrames[id], let pill = pillFrames[id] {
            SearchMarker(kind: kind)
                .snapsOpacity(movesContent)
                .modifier(morph(from: card, to: pill, scale: 1))
        }
    }

    /// Draws the card font. The scale brings it to the pill font size when collapsed.
    @ViewBuilder
    private func movingLabel(_ text: String, id: String) -> some View {
        if let card = cardFrames[id], let pill = pillFrames[id] {
            let scale = pillScale(card: card, pill: pill)
            Text(text)
                .font(.system(.body, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .snapsOpacity(movesContent)
                .frame(maxWidth: labelMaxWidth(card: card, scale: scale), alignment: .leading)
                .frame(height: card.height)
                .modifier(morph(from: card, to: pill, scale: scale))
        }
    }

    /// One progress value drives the position and the scale of a marker or a text, so every
    /// item of the layer reaches its pill or card frame on the same frame of the spring.
    private func morph(from card: CGRect, to pill: CGRect, scale: CGFloat) -> MorphEffect {
        MorphEffect(
            progress: mode == .collapsed ? 1 : 0,
            from: card.origin,
            to: pill.origin,
            scale: scale
        )
    }

    private func pillScale(card: CGRect, pill: CGRect) -> CGFloat {
        guard pill.height > 0, card.height > 0 else { return 1 }
        return pill.height / card.height
    }

    /// The card text width when expanded and the pill text width when collapsed, so the text
    /// truncates the same way as the field and the pill, and the spring interpolates the width.
    private func labelMaxWidth(card: CGRect, scale: CGFloat) -> CGFloat {
        switch mode {
        case .expanded: card.width
        case .collapsed: CommuteRoutePill.textMaxWidth / scale
        }
    }
}

/// Moves a view from `from` to `to` and scales it from 1 to `scale` about its top-leading
/// corner, all from one animatable `progress`.
private struct MorphEffect: GeometryEffect {
    var progress: CGFloat
    let from: CGPoint
    let to: CGPoint
    let scale: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let factor = 1 + (scale - 1) * progress
        let x = from.x + (to.x - from.x) * progress
        let y = from.y + (to.y - from.y) * progress
        let transform = CGAffineTransform(scaleX: factor, y: factor)
            .concatenating(CGAffineTransform(translationX: x, y: y))
        return ProjectionTransform(transform)
    }
}
