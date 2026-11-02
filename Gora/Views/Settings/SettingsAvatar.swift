//
//  SettingsAvatar.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// A Haze circle that shows the initials of a name.
struct SettingsAvatar: View {
    let name: String
    let diameter: CGFloat
    let font: Font

    var body: some View {
        Text(initials)
            .font(font)
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(Color.haze, in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
