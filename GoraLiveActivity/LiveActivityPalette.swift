//
//  LiveActivityPalette.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// A color that switches with the interface style, so the Lock Screen card follows light and dark.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(Color(hex: hex))
        })
    }
}

/// Monochrome colors of the Lock Screen card and the Dynamic Island.
enum LiveActivityPalette {
    static let background = Color.adaptive(light: 0xF2F2F2, dark: 0x1F1F1F)
    static let primary = Color.adaptive(light: 0x111111, dark: 0xF2F2F2)
    static let secondary = Color.adaptive(light: 0x5C5C5C, dark: 0xA3A3A3)
    static let tertiary = Color.adaptive(light: 0x8A8A8A, dark: 0x7A7A7A)
    static let track = Color.adaptive(light: 0xCFCFCF, dark: 0x454545)
    static let done = Color.adaptive(light: 0x222222, dark: 0xE8E8E8)

    static let islandText = Color.white
    static let islandSecondary = Color(hex: 0xA3A3A3)
    static let islandTertiary = Color(hex: 0x8A8A8A)
    static let islandTrack = Color(hex: 0x454545)
    static let islandWalk = Color(hex: 0x7A7A7A)
    static let islandDone = Color(hex: 0xE8E8E8)
}
