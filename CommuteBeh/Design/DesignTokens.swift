//
//  DesignTokens.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI

// MARK: - Design Tokens
// Founding token set, specified in .claude/audits/home-admin-ui-audit.md
// ("New Design Tokens Needed"). UI code should consume these tokens, not literals.

enum DesignTokens {

    // MARK: Type scale — Dynamic Type text styles only, never fixed point sizes
    enum TypeScale {
        /// Total trip time on the result card — the decision number.
        static let metric: Font = .title2.bold().monospacedDigit()
        /// Fare / distance beside the trip time.
        static let metricSecondary: Font = .headline.monospacedDigit()
        /// Leg instructions, card headers.
        static let cardTitle: Font = .headline
        /// Field text, suggestion names.
        static let body: Font = .subheadline
        /// Timestamps, line labels, stop counts.
        static let meta: Font = .caption
        /// Any lat/lng display (shared with Admin).
        static let coord: Font = .caption.monospacedDigit()
    }

    // MARK: Spacing scale
    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
    }

    // MARK: Corner radius
    enum Radius {
        /// Cards: search panel, result card.
        static let card: CGFloat = 16
        /// Controls: fields, suggestion list.
        static let control: CGFloat = 12
        // Pills are capsules — no numeric token.
    }

    // MARK: Semantic colors
    enum Colors {
        /// Interactive elements, prominent buttons (#127BED — the de-facto brand blue).
        static let accent = Color(red: 0x12 / 255.0, green: 0x7B / 255.0, blue: 0xED / 255.0)
        /// Route found, origin dot, save success.
        static let success = Color(.systemGreen)
        /// Destination pin, errors.
        static let destructive = Color(.systemRed)
        /// Delays/incidents, pending states.
        static let warning = Color(.systemOrange)

        // MARK: Results surface
        // The results panel and its cards are a deliberately light-only surface
        // (paper fill + hard ink outline), so these are fixed values rather than
        // semantic system colors — `Color.primary` would invert the outline to
        // white on the still-white card in dark mode.

        /// Hard outline on paper-filled cards and pills.
        static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
        /// Card fill on the results surface.
        static let paper = Color(red: 0.996, green: 0.988, blue: 0.973)
        /// Panel background behind the result cards.
        static let cream = Color(red: 0.96, green: 0.94, blue: 0.90)
        /// Primary action — the one thing to tap on a surface. Filled capsules only
        /// ("USE THIS ROUTE"); at 3.3:1 on `paper` it clears AA for large bold text
        /// but not for small text, so it must not be used below 14 pt bold.
        static let action = Color(red: 0.91, green: 0.38, blue: 0.16)

        /// "FASTEST" label badge.
        static let fastest = Color(red: 0.22, green: 0.45, blue: 0.87)
        /// "CHEAPEST" label badge.
        static let cheapest = Color(red: 0.13, green: 0.42, blue: 0.44)
    }

    // MARK: Motion patterns
    enum Motion {
        /// motion.cardEnter — result card slide-in: "the answer arrived".
        static let cardEnter: Animation = .spring(response: 0.35, dampingFraction: 0.85)
        /// motion.suggestEnter — suggestion list appear/disappear.
        static let suggestEnter: Animation = .easeOut(duration: 0.2)
        /// motion.cameraFit — map camera glide to a route's bounds.
        static let cameraFit: Animation = .easeInOut(duration: 0.5)
        /// motion.disclose — disclosure expand/collapse.
        static let disclose: Animation = .easeInOut(duration: 0.2)
        /// motion.morph — result card ⇄ full route details.
        /// Deliberately longer and softer than `disclose`: the whole panel changes
        /// shape while the duration/fare pair flies across it, and the eye needs
        /// time to follow that. A stiffer spring settles inside ~200 ms, which
        /// reads as a cut rather than a transition.
        static let morph: Animation = .spring(response: 0.55, dampingFraction: 0.86)
        /// motion.searchProgress — inline progress shows only past this grace delay…
        static let progressGraceDelay: Duration = .milliseconds(250)
        /// …and once shown stays visible at least this long, to avoid flicker.
        static let progressMinVisible: Duration = .milliseconds(500)
    }
}

// MARK: - Elevation
extension View {
    /// shadow.card — the only card shadow: black 15 %, radius 8.
    /// Positive y for top-anchored cards, negative for bottom-anchored ones.
    func cardShadow(y: CGFloat = 4) -> some View {
        shadow(color: .black.opacity(0.15), radius: 8, y: y)
    }
}

// MARK: - TransportMode styling
// Consolidates the three private modeColor(_:)/modeIcon(_:) copies that had
// drifted apart in ContentView / RouteResultCard / RouteLegRow.
extension TransportMode {

    var color: Color {
        switch self {
        case .train:    return .blue
        case .bus:      return .orange
        case .jeepney:  return .green
        case .tricycle: return .purple
        case .walk:     return Color(.systemGray)
        }
    }

    /// Jeepney deliberately shares bus.fill — car.fill read as a private car;
    /// jeepney green vs. bus orange keeps the two distinguishable.
    var icon: String {
        switch self {
        case .train:    return "tram.fill"
        case .bus:      return "bus.fill"
        case .jeepney:  return "bus.fill"
        case .tricycle: return "bicycle"
        case .walk:     return "figure.walk"
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .train:    return 5
        case .bus:      return 4
        case .jeepney:  return 4
        case .tricycle: return 3
        case .walk:     return 2
        }
    }
}
