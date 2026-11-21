//
//  ScrollEdgeFade.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/15/26.
//

import SwiftUI

// MARK: - Scroll Edge Fade

/// The edge of a scroll view that fades out while content is hidden past it.
enum ScrollFadeEdge {
    case trailing
    case bottom
}

extension View {
    /// Fades the given edge over `length` points while content is hidden past it.
    /// Apply it directly to the `ScrollView`, because it reads the nearest scroll view.
    func scrollEdgeFade(_ edge: ScrollFadeEdge, length: CGFloat) -> some View {
        modifier(ScrollEdgeFadeModifier(edge: edge, length: length))
    }
}

private struct ScrollEdgeFadeModifier: ViewModifier {
    let edge: ScrollFadeEdge
    let length: CGFloat
    @State private var isFaded = false

    private enum Layout {
        static let hiddenTolerance: CGFloat = 1
        static let animationDuration = 0.2
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                hiddenAmount(in: geometry) > Layout.hiddenTolerance
            } action: { _, newValue in
                isFaded = newValue
            }
            .mask { fadeMask }
            .animation(.easeOut(duration: Layout.animationDuration), value: isFaded)
    }

    private func hiddenAmount(in geometry: ScrollGeometry) -> CGFloat {
        switch edge {
        case .trailing:
            geometry.contentSize.width + geometry.contentInsets.trailing
                - geometry.containerSize.width - geometry.contentOffset.x
        case .bottom:
            geometry.contentSize.height + geometry.contentInsets.bottom
                - geometry.containerSize.height - geometry.contentOffset.y
        }
    }

    /// An opaque area plus a fixed-length gradient. The gradient stays opaque while `isFaded` is false.
    @ViewBuilder
    private var fadeMask: some View {
        switch edge {
        case .trailing:
            HStack(spacing: 0) {
                Color.black
                fadeGradient(.trailing).frame(width: length)
            }
        case .bottom:
            VStack(spacing: 0) {
                Color.black
                fadeGradient(.bottom).frame(height: length)
            }
        }
    }

    private func fadeGradient(_ end: UnitPoint) -> some View {
        let start: UnitPoint = end == .trailing ? .leading : .top
        return LinearGradient(colors: [.black, isFaded ? .clear : .black], startPoint: start, endPoint: end)
    }
}
