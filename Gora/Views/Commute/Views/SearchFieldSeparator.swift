//
//  SearchFieldSeparator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

/// The hairline between the origin and destination rows. It starts under the text, like an inset list row.
struct SearchFieldSeparator: View {
    /// Height of the separator. The panel adds it to a row height to get the row distance.
    static let height: CGFloat = 1

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(Layout.opacity))
            .frame(height: Layout.lineWidth)
            .frame(height: Self.height, alignment: .center)
            .accessibilityHidden(true)
    }
}

/// The dotted line between the origin and destination markers. It shows that the trip goes from top to bottom.
struct SearchFieldRail: View {
    let length: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: Layout.dotSize / 2, y: Layout.dotSize / 2))
            path.addLine(to: CGPoint(x: Layout.dotSize / 2, y: max(length - Layout.dotSize / 2, Layout.dotSize / 2)))
        }
        .stroke(.tertiary, style: StrokeStyle(lineWidth: Layout.dotSize, lineCap: .round, dash: [0, Layout.dotPitch]))
        .frame(width: Layout.dotSize, height: max(length, Layout.dotSize))
        .accessibilityHidden(true)
    }

    static var width: CGFloat { Layout.dotSize }
}

private enum Layout {
    static let opacity: Double = 0.12
    static let lineWidth: CGFloat = 0.5
    static let dotSize: CGFloat = 3
    /// Distance from one dot center to the next.
    static let dotPitch: CGFloat = 6
}
