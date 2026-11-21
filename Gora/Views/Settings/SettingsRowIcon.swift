//
//  SettingsRowIcon.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// An outline SF Symbol in the `onyx` color. It takes the font of its row, so it matches the title.
/// The column has a fixed width, so titles align across rows.
struct SettingsRowIcon: View {
    let systemImage: String

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = Layout.columnWidth

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(Color.onyx)
            .frame(width: width)
    }
}

private enum Layout {
    static let columnWidth: CGFloat = 28
}

/// Shows the icon, then the title.
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

/// A row label: icon and title.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsRowIcon(systemImage: systemImage)
        }
        .labelStyle(.settingsIcon)
    }
}
