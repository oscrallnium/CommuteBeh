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

/// A strip-bottom value that eases from its previous value to a new target over the card's
/// disclosure duration, using the same ease-in-out shape as the card animation.
struct StripBottomEase {
    private var from: CGFloat
    private var to: CGFloat
    private var start: Date

    init(_ value: CGFloat, now: Date) {
        from = value
        to = value
        start = now
    }

    func value(at now: Date) -> CGFloat {
        let duration = DesignTokens.Motion.discloseDuration
        let fraction = min(1, max(0, now.timeIntervalSince(start) / duration))
        let eased = fraction * fraction * (3 - 2 * fraction)
        return from + (to - from) * CGFloat(eased)
    }

    /// Starts a new ease from the current value when `target` differs from the last target.
    mutating func retarget(_ target: CGFloat, now: Date) {
        guard target != to else { return }
        from = value(at: now)
        to = target
        start = now
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
