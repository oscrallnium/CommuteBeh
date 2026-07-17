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
