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
        /// motion.cameraFitDuration — length of one camera glide, in seconds. Named because
        /// `Animation` does not expose its duration and the heading loop must gate itself for
        /// exactly this long. See `ContentView.isCameraTransitioning`.
        static let cameraFitDuration: TimeInterval = 0.5
        /// motion.cameraFit — map camera glide to a route's bounds.
        static let cameraFit: Animation = .easeInOut(duration: cameraFitDuration)
        /// motion.headingTickInterval — cadence of the 3D camera's own heading-smoothing
        /// loop (`ContentView.advanceDisplayedHeading()`), which eases toward the compass
        /// reading at a fixed rate instead of re-animating on every raw, irregularly-timed
        /// sensor sample.
        static let headingTickInterval: TimeInterval = 1.0 / 30.0
        /// motion.headingFollow — one heading-smoothing tick's camera write. Duration
        /// matches `headingTickInterval` exactly so consecutive ticks hand off with no
        /// gap and no overlap — either one reintroduces a lag this loop exists to remove.
        /// Linear, not eased: a curve that decelerates before the next tick lands falls
        /// behind, which is what read as lag before this was a fixed-rate loop.
        static let headingFollow: Animation = .linear(duration: headingTickInterval)
        /// motion.locationFollowMinDuration — shortest glide a GPS-driven camera move is
        /// allowed, even when two fixes land almost back to back. Below this a linear
        /// glide reads as a flicker rather than motion.
        static let locationFollowMinDuration: TimeInterval = 0.3
        /// motion.locationFollowMaxDuration — longest glide a GPS-driven camera move is
        /// allowed, when fixes are sparse. Past this a slow crawl reads as lag rather
        /// than travel, so the camera instead arrives promptly and waits.
        static let locationFollowMaxDuration: TimeInterval = 1.5
        /// motion.locationFollow — one GPS fix's camera write, paced to the time since the
        /// previous fix (clamped to the bounds above) rather than a fixed duration, so
        /// consecutive glides hand off the way `headingFollow` hands off between compass
        /// ticks instead of decelerating to a stop and waiting on `cameraFit`'s curve.
        static func locationFollow(elapsedSinceLastFix: TimeInterval) -> Animation {
            .linear(duration: min(max(elapsedSinceLastFix, locationFollowMinDuration), locationFollowMaxDuration))
        }
        /// motion.locationCorrection — a train leg's async track-snap landing after the
        /// camera already moved on the raw fix. Short and linear: this corrects the last
        /// glide's endpoint, it is not a new one, so it must not read as its own move.
        static let locationCorrection: Animation = .linear(duration: 0.15)
        /// motion.disclose — disclosure expand/collapse.
        static let disclose: Animation = .easeInOut(duration: 0.2)
        /// motion.morph — result card ⇄ full route details.
        /// Deliberately longer and softer than `disclose`: the whole panel changes
        /// shape while the duration/fare pair flies across it, and the eye needs
        /// time to follow that. A stiffer spring settles inside ~200 ms, which
        /// reads as a cut rather than a transition.
        static let morph: Animation = .spring(response: 0.55, dampingFraction: 0.86)
        // The passenger dot's motion between GPS fixes is deliberately not a token here.
        // It is `UserAnnotation`, which MapKit animates with the same puck animator Maps
        // uses — the pacing is Apple's, and there is nothing for us to specify.
        /// motion.locationPulse — the passenger dot's idle breathe while standing still.
        /// The one respect in which the dot's motion is ours rather than MapKit's: see
        /// `PassengerPuck`.
        static let locationPulse: Animation = .easeInOut(duration: 1.0).repeatForever(autoreverses: true)

        /// motion.accuracyChange — GPS accuracy circle resize as horizontal accuracy
        /// improves or degrades between fixes.
        static let accuracyChange: Animation = .easeInOut(duration: 0.5)
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

// MARK: - StationAccessPoint styling
//
// Admin-only, and deliberately not reusing the transport-mode palette: a door is not a
// mode, and colouring it by line would make two doors of the same station indistinguishable
// on the map, which is exactly what the editor exists to tell apart.
extension StationAccessPoint {
    /// Entrances point in, exits point out, shared doors show both.
    var symbol: String { kind.symbol }

    /// Direction is the field most likely to be set wrong, so it drives the colour:
    /// undirected doors are neutral, northbound and southbound are told apart at a glance.
    var directionTint: Color {
        switch direction {
        case "northbound": return DesignTokens.Colors.fastest
        case "southbound": return DesignTokens.Colors.cheapest
        default:           return DesignTokens.Colors.action
        }
    }
}

extension StationAccessPoint.Kind {
    var symbol: String {
        switch self {
        case .entrance: return "arrow.down.right.and.arrow.up.left"
        case .exit:     return "arrow.up.left.and.arrow.down.right"
        case .both:     return "arrow.left.arrow.right"
        }
    }
}
