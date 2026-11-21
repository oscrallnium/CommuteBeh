//
//  GoraGlass.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import SwiftUI

extension View {
    /// Draws Liquid Glass behind the view. A solid background replaces it when the passenger turns Liquid Glass off.
    /// The solid background uses `tint`, or `fallbackColor` when the glass has no tint.
    func goraGlass(
        _ glass: Glass,
        tint: Color? = nil,
        fallbackColor: Color = .vellum,
        in shape: some Shape
    ) -> some View {
        modifier(GoraGlassModifier(glass: glass, tint: tint, fallbackColor: fallbackColor, shape: shape))
    }
}

private struct GoraGlassModifier<S: Shape>: ViewModifier {
    let glass: Glass
    let tint: Color?
    let fallbackColor: Color
    let shape: S

    @AppStorage(SettingsKey.liquidGlassEnabled) private var isGlassEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isGlassEnabled {
            content.glassEffect(tint.map { glass.tint($0) } ?? glass, in: shape)
        } else {
            content.background { shape.fill(fallbackFill).cardShadow(y: 0) }
        }
    }

    private var fallbackFill: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(fallbackColor)
    }
}
