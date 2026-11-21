//
//  TypeScaleModifier.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/7/26.
//

import SwiftUI

/// Applies a `TypeScale` size, scaled by Dynamic Type relative to the style's text style.
private struct TypeScaleModifier: ViewModifier {
    let style: DesignTokens.TypeScale
    @ScaledMetric private var size: CGFloat

    init(style: DesignTokens.TypeScale) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight))
    }
}

extension View {
    /// Sets the font to a `TypeScale` case in SF Pro, scaled with Dynamic Type.
    func typeScale(_ style: DesignTokens.TypeScale) -> some View {
        modifier(TypeScaleModifier(style: style))
    }
}
