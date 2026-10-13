//
//  DesignTokens.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI

// MARK: - Design Tokens
// UI code consumes these tokens, not literals. See Design.md.

enum DesignTokens {

    // MARK: Type scale — Dynamic Type text styles only, never fixed point sizes
    enum TypeScale {
        /// Largest figure on a card, such as the trip duration.
        static let display: Font = .largeTitle.bold()
        /// Stat value, such as a fare or an arrival time.
        static let statValue: Font = .title2.bold()
        /// Arrival time on the commute card.
        static let eta: Font = .title2.weight(.semibold)
        /// Unit beside a display figure.
        static let instruction: Font = .title3.weight(.semibold)
        /// Title of a compact card.
        static let instructionCompact: Font = .headline
        /// Label of a control, and the route time bubble text.
        static let controlLabel: Font = .callout.weight(.semibold)
        /// Row title and chip title.
        static let rowTitle: Font = .subheadline.weight(.semibold)
        /// Title of the current row.
        static let rowTitleCurrent: Font = .subheadline.bold()
        /// Subtitle and stat label.
        static let subtitle: Font = .footnote
        /// Badge and chip text.
        static let subtitleEmphasis: Font = .footnote.weight(.semibold)
        /// Field text, suggestion names.
        static let body: Font = .subheadline
        /// Timestamps, line labels, stop counts.
        static let meta: Font = .caption
    }

    // MARK: Spacing scale
    enum Space {
        static let xxs: CGFloat = 3
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        /// Vertical padding of a leg row.
        static let legRow: CGFloat = 9
        static let sm: CGFloat = 10
        static let m: CGFloat = 12
        static let ml: CGFloat = 14
        /// Screen gutter.
        static let l: CGFloat = 16
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 22
    }

    // MARK: Corner radius
    enum Radius {
        /// Cards: search panel, result card.
        static let card: CGFloat = 16
        /// Controls: fields, suggestion list.
        static let control: CGFloat = 12
        /// Badges and leg chips.
        static let badge: CGFloat = 7
        /// Grabber bar.
        static let indicator: CGFloat = 3
        /// Floating route choice sheet.
        static let routeSheet: CGFloat = 34
        /// Floating Commute Mode card. A rounded rectangle, not a capsule.
        static let commuteSheet: CGFloat = 30
        // Pills are capsules — no numeric token.
    }

    // MARK: Semantic colors
    enum Colors {
        /// Primary action: the one thing to tap on a surface. A Tangerine fill takes
        /// Licorice text, never white, because white on Tangerine is about 2.4:1.
        static let action = Color.tangerine

        /// Halo around the position puck: `Color.tangerine` at 22 %.
        static let positionHalo = Color.tangerine.opacity(0.22)
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
        /// motion.cameraPoseDuration — length of a 2D/3D switch or a follow re-attach, in seconds.
        static let cameraPoseDuration: TimeInterval = 0.7
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
        /// motion.routeEmphasis — length of the map line change when the selected route switches.
        static let routeEmphasis: Animation = .easeOut(duration: 0.3)
        /// motion.discloseDuration — length of one disclosure expand/collapse, in seconds.
        static let discloseDuration: TimeInterval = 0.2
        /// motion.disclose — disclosure expand/collapse.
        static let disclose: Animation = .easeInOut(duration: discloseDuration)
        /// motion.morph — result card ⇄ full route details.
        /// Deliberately longer and softer than `disclose`: the whole panel changes
        /// shape while the duration/fare pair flies across it, and the eye needs
        /// time to follow that. A stiffer spring settles inside ~200 ms, which
        /// reads as a cut rather than a transition.
        static let morph: Animation = .spring(response: 0.55, dampingFraction: 0.86)
        /// motion.controlMorph — the map control circles merging into one and splitting again.
        static let controlMorph: Animation = .spring()
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

// MARK: - Hex color
extension Color {
    /// Parses `#RRGGBB`. Returns nil for any other format.
    init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - TransportMode styling
extension TransportMode {

    var color: Color {
        switch self {
        case .train:    return .orchid
        case .bus:      return .cobalt
        case .jeepney:  return .amethyst
        case .tricycle: return .chartreuse
        case .walk:     return .mist
        }
    }

    /// Jeepney shares bus.fill because car.fill reads as a private car.
    /// Jeepney amethyst and bus cobalt keep the two distinguishable.
    var icon: String {
        switch self {
        case .train:    return "tram.fill"
        case .bus:      return "bus.fill"
        case .jeepney:  return "bus.fill"
        case .tricycle: return "bicycle"
        case .walk:     return "figure.walk"
        }
    }
}

// MARK: - Route line geometry
/// Map route line dimensions, in points.
enum RouteLine {
    /// Solid core width of a leg.
    static let coreWidth: CGFloat = 6
    /// Core width of the leg the passenger rides now.
    static let currentWidth: CGFloat = 7
    /// Casing width on each side of a core.
    static let casing: CGFloat = 2
    /// Walking dot diameter.
    static let walkDot: CGFloat = 5
    /// Distance between walking dot centers.
    static let walkPitch: CGFloat = 9

    /// Walking dots at the default scale.
    static let walk = walkStyle()
    /// Thin solid stroke of a station access connector.
    static let connectorStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round)

    /// Round dots in `walkDot` size on `walkPitch`, scaled by `scale`. The dash is near zero
    /// so each round cap draws a full circle.
    static func walkStyle(scale: Double = 1) -> StrokeStyle {
        StrokeStyle(lineWidth: walkDot * scale, lineCap: .round, lineJoin: .round,
                    dash: [0.01, walkPitch * scale - 0.01])
    }

    /// Solid round-capped stroke of `width`.
    static func solidStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
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

    /// Direction drives the marker lightness. Northbound is darkest, southbound is mid grey,
    /// undirected is light grey. Fixed values keep the white symbol readable in both appearances.
    var directionTint: Color {
        switch direction {
        case "northbound": return Color.licorice
        case "southbound": return Color(white: 0.38)
        default:           return Color(white: 0.52)
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
