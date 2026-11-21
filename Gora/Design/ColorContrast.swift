//
//  ColorContrast.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

extension Color {
    private enum IconContrast {
        static let minimumRatio = 3.0
    }

    /// Relative luminance per WCAG 2.x. Inputs are gamma-encoded sRGB components in 0...1.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// `Color.licorice` or `Color.white`, whichever has the higher contrast ratio on a fill of the
    /// given luminance. Licorice (#16110C) has a luminance of about 0.006.
    static func inkLuminance(onFillLuminance fill: Double) -> Color {
        let darkRatio = (fill + 0.05) / (0.006 + 0.05)
        let lightRatio = 1.05 / (fill + 0.05)
        return darkRatio >= lightRatio ? .licorice : .white
    }

    /// The ink that reads best on this color as a fill, resolved for the given environment.
    func contrastingInk(in environment: EnvironmentValues) -> Color {
        let resolved = resolve(in: environment)
        let luminance = Color.relativeLuminance(
            red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
        return Color.inkLuminance(onFillLuminance: luminance)
    }

    /// The ink for a glyph on this color as a fill: white when it reaches 3:1 contrast (WCAG 1.4.11),
    /// else licorice. Use `contrastingInk(in:)` for text.
    func iconInk(in environment: EnvironmentValues) -> Color {
        let resolved = resolve(in: environment)
        let luminance = 0.2126 * Double(resolved.linearRed)
            + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
        return 1.05 / (luminance + 0.05) >= IconContrast.minimumRatio ? .white : .licorice
    }
}
