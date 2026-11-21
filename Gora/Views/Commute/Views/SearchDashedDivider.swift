//
//  SearchDashedDivider.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import SwiftUI

/// The dashed line between the origin and destination rows.
struct SearchDashedDivider: View {
    /// Height of the divider. The panel adds it to a row height to get the row distance.
    static let height: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: Layout.lineY))
                path.addLine(to: CGPoint(x: geo.size.width, y: Layout.lineY))
            }
            .stroke(Color.primary.opacity(Layout.opacity),
                    style: StrokeStyle(lineWidth: Layout.lineWidth, dash: Layout.dash))
        }
        .frame(height: Self.height)
    }
}

private enum Layout {
    static let lineY: CGFloat = 0.5
    static let opacity: Double = 0.15
    static let lineWidth: CGFloat = 1
    static let dash: [CGFloat] = [5, 4]
}
