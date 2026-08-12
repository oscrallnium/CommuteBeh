//
//  CommuteLayoutKeys.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

// MARK: - Preference Keys

/// Top edge of the results panel in global coordinates, where the visible map strip ends.
/// Carries a position rather than a height, so it needs no assumption about the tab bar or
/// the home indicator below it.
struct VisibleBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Visible Top Key

/// Bottom edge of the search panel in global coordinates — where the visible map strip
/// begins.
struct VisibleTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's bottom edge plus `outerPadding` as the top of the visible map
    /// strip. Apply it to the search card or the collapsed pill only — never to a container
    /// that also holds the suggestion list, which covers the map transiently.
    func measuresVisibleTop(outerPadding: CGFloat) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: VisibleTopKey.self,
                                       value: geo.frame(in: .global).maxY + outerPadding)
            }
        )
    }
}

// MARK: - Cards Branch Height Key

struct CardsBranchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Minimized Row Height Key

struct MinimizedRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Leg Row Heights Key

/// Height of each leg row, keyed by row id, so the detail list can cap its viewport at the
/// first three rows. Merges every row's value rather than reducing to one, because the cap
/// needs the sum of a known subset.
struct LegRowHeightsKey: PreferenceKey {
    static let defaultValue: [RouteCardSummary.LegRow.ID: CGFloat] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { max($0, $1) }
    }
}
