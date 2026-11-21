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
}

/// Monochrome colors of the Lock Screen card and the Dynamic Island. Both always use dark colors.
enum LiveActivityPalette {
    static let background = Color(hex: 0x1F1F1F)
    static let primary = Color(hex: 0xF2F2F2)
    static let secondary = Color(hex: 0xA3A3A3)
    static let tertiary = Color(hex: 0x7A7A7A)
    static let track = Color(hex: 0x454545)
    static let done = Color(hex: 0xE8E8E8)

    static let islandText = Color.white
    static let islandSecondary = Color(hex: 0xA3A3A3)
    static let islandTertiary = Color(hex: 0x8A8A8A)
    static let islandTrack = Color(hex: 0x454545)
    static let islandWalk = Color(hex: 0x7A7A7A)
    static let islandDone = Color(hex: 0xE8E8E8)
}
