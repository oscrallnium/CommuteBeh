//
//  CompressibleSection.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import SwiftUI

/// A section of the route sheet that shrinks to zero height and fades out as `progress` goes
/// from 0 to 1. It reports the natural height of its content, which the drag uses as its range.
struct CompressibleSection<Content: View>: View {
    let progress: CGFloat
    @Binding var naturalHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        CompressLayout(progress: progress) {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { naturalHeight = $0 }
        }
        .clipped()
        .opacity(1 - progress)
        .allowsHitTesting(progress < 1)
        .accessibilityHidden(progress >= 1)
    }
}

/// Lays out its one subview at natural height, then reports a height scaled by `1 - progress`.
/// `progress` is animatable, so a `withAnimation` change morphs the height with the same curve.
private struct CompressLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * (1 - progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
