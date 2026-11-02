//
//  SettingsRowIcon.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// A rounded square filled with `tint` that holds one white, filled SF Symbol, like the icons in
/// iOS Settings. The fill uses the light-mode value of `tint`, so the icon looks the same in both
/// modes. The square scales with Dynamic Type.
struct SettingsRowIcon: View {
    let systemImage: String
    let tint: Color

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
    }

    var body: some View {
        Image(systemName: systemImage)
            .symbolVariant(.fill)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background { fill }
    }

    /// The tint with a faint lighter top, resolved in light mode.
    private var fill: some View {
        shape.fill(tint)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear],
                                               startPoint: .top, endPoint: .bottom)))
            .environment(\.colorScheme, .light)
    }
}

/// Shows the icon square, then the title.
struct SettingsIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DesignTokens.Space.m) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == SettingsIconLabelStyle {
    static var settingsIcon: SettingsIconLabelStyle { SettingsIconLabelStyle() }
}

/// A row label: icon square and title.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsRowIcon(systemImage: systemImage, tint: tint)
        }
        .labelStyle(.settingsIcon)
    }
}
