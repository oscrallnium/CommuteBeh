//
//  SearchPanelMode.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import SwiftUI

/// The panel layout: the full card with its extras, or the pill beside a back button.
enum SearchPanelMode: Equatable {
    case expanded, collapsed

    /// The card radius when expanded, half the pill height when collapsed.
    var surfaceRadius: CGFloat {
        switch self {
        case .expanded: DesignTokens.Radius.card
        case .collapsed: CommuteRoutePill.height / 2
        }
    }

    /// The charcoal tint shows only behind the card.
    var tintOpacity: Double {
        switch self {
        case .expanded: Layout.cardTintOpacity
        case .collapsed: 0
        }
    }
}

private enum Layout {
    static let cardTintOpacity: Double = 0.35
}
