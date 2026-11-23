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

/// A strip-bottom value that moves from its previous value to a new target along the commute
/// card spring, so the map and the card settle together.
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
        let spring = DesignTokens.Motion.cardEnterSpring
        let elapsed = max(0, now.timeIntervalSince(start))
        guard elapsed < spring.settlingDuration else { return to }
        let progress = spring.value(target: 1.0, initialVelocity: 0.0, time: elapsed)
        return from + (to - from) * CGFloat(progress)
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
