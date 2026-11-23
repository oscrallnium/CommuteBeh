//
//  SheetActionSize.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import SwiftUI

/// Size shared by the two sheet action buttons. The height scales with the same text style as the label.
struct SheetActionSize: ViewModifier {
    private enum Layout {
        static let height: CGFloat = 53
        static let horizontalPadding: CGFloat = 20
    }

    @ScaledMetric(relativeTo: .body) private var height = Layout.height

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Layout.horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
