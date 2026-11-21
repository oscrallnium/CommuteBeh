//
//  SearchSuggestionDropdown.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import SwiftUI

/// A `SuggestionList` on a material card with a shadow. It sits outside the search card, so
/// the card edge does not cut it off.
struct SearchSuggestionDropdown: View {
    let suggestions: [LocationSuggestion]
    let lineName: (String) -> String
    let lineColor: (String) -> Color?
    let onSelect: (LocationSuggestion) -> Void

    var body: some View {
        SuggestionList(
            suggestions: Array(suggestions.prefix(Layout.suggestionLimit)),
            lineName: lineName,
            lineColor: lineColor,
            onSelect: onSelect
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        .cardShadow(y: Layout.shadowY)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private enum Layout {
    static let suggestionLimit = 5
    static let shadowY: CGFloat = 4
}
