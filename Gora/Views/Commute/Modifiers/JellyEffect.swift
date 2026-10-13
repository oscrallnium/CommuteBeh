//
//  JellyEffect.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/29/26.
//

import SwiftUI

/// Springs the view's container when `trigger` changes. It compresses to `1 - intensity`,
/// then overshoots slightly before settling.
/// Usage: `card.jellyEffect(trigger: isExpanded)`.
struct JellyEffect<T: Equatable>: ViewModifier {
    let trigger: T
    var intensity: CGFloat = 0.04

    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.0 - intensity
                withAnimation(.spring(response: 0.38, dampingFraction: 0.28)) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    func jellyEffect(trigger: some Equatable, intensity: CGFloat = 0.04) -> some View {
        modifier(JellyEffect(trigger: trigger, intensity: intensity))
    }
}
