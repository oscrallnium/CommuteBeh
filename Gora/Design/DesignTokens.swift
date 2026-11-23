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

    // MARK: Type scale — SF Pro at explicit sizes that scale with Dynamic Type. Apply with `.typeScale(_:)`.
    enum TypeScale {
        /// Largest figure on a card, such as the trip duration.
        case display
        /// Stat value, such as a fare or an arrival time.
        case statValue
        /// Arrival time on the commute card.
        case eta
        /// Unit beside a display figure.
        case instruction
        /// Title of a compact card.
        case instructionCompact
        /// Label of a control, and the route time bubble text.
        case controlLabel
        /// Label of the primary and secondary buttons in the route sheet.
        case sheetActionLabel
        /// Row title and chip title.
        case rowTitle
        /// Title of the current row.
        case rowTitleCurrent
        /// Subtitle and stat label.
        case subtitle
        /// Badge and chip text.
        case subtitleEmphasis
        /// Field text, suggestion names.
        case body
        /// Arrival time on the commute card header.
        case etaLarge
        /// Subtitle of the commute card header.
        case bodyLarge
        /// Leg title on the commute card.
        case rowTitleLarge
        /// Title of the current leg on the commute card.
        case rowTitleLargeCurrent
        /// Timestamps, line labels, stop counts.
        case meta

        /// Point size at the default Dynamic Type setting.
        var size: CGFloat {
            switch self {
            case .display: 34
            case .statValue: 22
            case .eta: 22
            case .instruction: 20
            case .instructionCompact: 17
            case .controlLabel: 20
            case .sheetActionLabel: 17
            case .rowTitle: 15
            case .rowTitleCurrent: 15
            case .subtitle: 13
            case .subtitleEmphasis: 13
            case .body: 15
            case .etaLarge: 28
            case .bodyLarge: 17
            case .rowTitleLarge: 17
            case .rowTitleLargeCurrent: 17
            case .meta: 12
            }
        }

        var weight: Font.Weight {
            switch self {
            case .display: .bold
            case .statValue: .bold
            case .eta: .semibold
            case .instruction: .semibold
            case .instructionCompact: .semibold
            case .controlLabel: .medium
            case .sheetActionLabel: .semibold
            case .rowTitle: .semibold
            case .rowTitleCurrent: .bold
            case .subtitle: .regular
            case .subtitleEmphasis: .bold
            case .body: .regular
            case .etaLarge: .semibold
            case .bodyLarge: .regular
            case .rowTitleLarge: .semibold
            case .rowTitleLargeCurrent: .bold
            case .meta: .regular
            }
        }

        /// Text style whose scaling curve the size follows.
        var relativeTo: Font.TextStyle {
            switch self {
            case .display: .largeTitle
            case .statValue: .title2
            case .eta: .title2
            case .instruction: .title3
            case .instructionCompact: .headline
            case .controlLabel: .title
            case .sheetActionLabel: .body
            case .rowTitle: .subheadline
            case .rowTitleCurrent: .subheadline
            case .subtitle: .footnote
            case .subtitleEmphasis: .footnote
            case .body: .subheadline
            case .etaLarge: .title
            case .bodyLarge: .body
            case .rowTitleLarge: .body
            case .rowTitleLargeCurrent: .body
            case .meta: .caption
            }
        }
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
        static let xxxl: CGFloat = 32
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
        /// Primary action: the one thing to tap on a surface. A Cobalt fill takes white text.
        static let action = Color.cobalt
        /// Text and symbols on an `action` fill.
        static let onAction = Color.white
        /// Text and symbol of a secondary button: the same blue as the primary action.
        static let secondaryAction = action
        /// Fill of a secondary button.
        static let secondaryActionFill = Color.haze

        /// Halo around the position puck: `Color.tangerine` at 22 %.
        static let positionHalo = Color.tangerine.opacity(0.22)

        /// Dimming layer under the route choice sheet's glass. The glass shows the dimmed map.
        /// Black at 55 % in dark mode and white at 35 % in light mode, so the text keeps its contrast.
        static let sheetDim = Color(UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.55)
                : UIColor.white.withAlphaComponent(0.35)
        })
    }

    // MARK: Materials
    enum Materials {
        /// Glass of a card over the map: frosted and tinted with `systemGray5`, a charcoal gray in dark
        /// mode and a light gray in light mode. A black tint makes the card near-black and opaque.
//        static let cardGlass = Glass.regular.tint(Color(.systemGray5).opacity(0.4))
        static let cardGlass = Glass.regular/*.tint(Color.graphite.opacity(0.35))*/
        /// Glass of the route choice sheet: frosted, so the map behind it shows only as blur and color.
        static let routeSheetGlass = Glass.regular

    }

    // MARK: Motion patterns
    enum Motion {
        /// motion.cardEnter — result card slide-in: "the answer arrived".
        static let cardEnter: Animation = .spring(cardEnterSpring)
        /// motion.cardEnterSpring — spring behind `cardEnter`; the map strip follows the same curve.
        static let cardEnterSpring = Spring(response: 0.35, dampingRatio: 0.85)
        /// motion.suggestEnter — suggestion list appear/disappear.
        static let suggestEnter: Animation = .easeOut(duration: 0.2)
        /// motion.cameraFitDuration — length of one camera glide, in seconds. Named because
        /// `Animation` does not expose its duration and the heading loop must gate itself for
        /// exactly this long. See `ContentView.isCameraTransitioning`.
        static let cameraFitDuration: TimeInterval = 0.5
        /// motion.geometryWaitCap — longest wait, in seconds, for walk and zone-ride paths
        /// before the camera fits and the route draws with the paths it has.
        static let geometryWaitCap: TimeInterval = 1.5
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
        /// motion.routeDetail — the route sheet's expand/collapse: `disclose` under Reduce Motion, else `morph`.
        static func routeDetail(reduceMotion: Bool) -> Animation { reduceMotion ? disclose : morph }
        /// motion.locationStateDuration — length of every Location-off animation, in seconds.
        static let locationStateDuration: TimeInterval = 0.3
        /// motion.locationState — banner, step change, row state, map leg and live-guidance switch.
        static let locationState: Animation = .easeInOut(duration: locationStateDuration)
        /// motion.locationBanner — the banner enters and leaves from `edge`. Reduce Motion uses a crossfade.
        static func locationBanner(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
        }
        /// motion.controlMorph — the map control circles merging into one and splitting again.
        static let controlMorph: Animation = .spring()
        // The passenger dot's motion between GPS fixes is deliberately not a token here.
        // It is MapKit's own user-location view, which MapKit animates with the same puck animator
        // Maps uses — the pacing is Apple's, and there is nothing for us to specify.
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

// MARK: - Map overlay alpha
extension Color {
    /// This color with `opacity` stored in the UIColor. MapKit overlay renderers ignore a
    /// SwiftUI `opacity(_:)` modifier, so map strokes and fills use this instead.
    func mapOpacity(_ opacity: Double) -> Color {
        Color(uiColor: UIColor(self).withAlphaComponent(opacity))
    }
}

// MARK: - Hex color
extension Color {
    /// Parses `#RRGGBB`. Returns nil for any other format.
    nonisolated init?(hex: String) {
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
        case .bus:      return .plum
        case .jeepney:  return .amethyst
        case .modernJeepney: return .lagoon
        case .uvExpress: return .amethyst
        case .tricycle: return .chartreuse
        case .walk:     return .cocoa
        }
    }

    /// The jeepney, the modern jeepney, and the tricycle use the custom `jeepney.fill`, `jeepney.modern.fill`, and `tricycle.fill`
    /// symbols in Assets.xcassets. The other modes use system symbols.
    var iconImage: Image {
        switch self {
        case .train:    return Image(systemName: "tram.fill")
        case .bus:      return Image(systemName: "bus.fill")
        case .jeepney:  return Image(.jeepneyFill)
        case .modernJeepney: return Image(.jeepneyModernFill)
        case .uvExpress: return Image(systemName: "car.side.fill")
        case .tricycle: return Image(.tricycleFill)
        case .walk:     return Image(systemName: "figure.walk")
        }
    }

    /// Name shown in mode pickers.
    var displayName: String {
        switch self {
        case .uvExpress: "UV Express"
        case .modernJeepney: "Modern Jeepney"
        default: rawValue.capitalized
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
    /// Solid width of a walk leg.
    static let walkWidth: CGFloat = 4
    /// Core width of the walk leg the passenger is on when position is unknown.
    static let currentWalkWidth: CGFloat = 5
    /// Opacity of a finished leg when position is unknown.
    static let doneOpacity: Double = 0.35

    /// Solid stroke of a walk leg.
    static let walkStyle = solidStyle(width: walkWidth)
    /// Thin solid stroke of a station access connector and of the walk connector.
    static let connectorStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round)

    /// Round-capped casing stroke under a leg core of `mode`. A walk leg cases its thinner core.
    static func casingStyle(for mode: TransportMode) -> StrokeStyle {
        solidStyle(width: (mode == .walk ? walkWidth : coreWidth) + 2 * casing)
    }

    /// Solid round-capped stroke of `width`.
    static func solidStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

// MARK: - Route casing
extension Color {
    /// Brightness factor of a light-mode casing.
    nonisolated private static let casingBrightness: CGFloat = 0.65
    /// Brightness factor of each safety step.
    nonisolated private static let casingStep: CGFloat = 0.9
    /// Lowest contrast ratio against white that a light-mode casing keeps.
    nonisolated private static let casingMinContrast: CGFloat = 3.0

    /// Casing of a route line drawn in this color. Light mode darkens the color to 3:1 contrast
    /// against white at least. Dark mode uses `Color.canvas`.
    var routeCasing: Color {
        let base = UIColor(self)
        let canvas = UIColor(Color.canvas)
        return Color(UIColor { @Sendable traits in
            if traits.userInterfaceStyle == .dark { return canvas.resolvedColor(with: traits) }
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            let resolved = base.resolvedColor(with: traits)
            guard resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                return resolved
            }
            brightness *= Color.casingBrightness
            var casing = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
            while brightness > 0.01, Color.contrastAgainstWhite(casing) < Color.casingMinContrast {
                brightness *= Color.casingStep
                casing = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
            }
            return casing
        })
    }

    /// WCAG contrast ratio of `color` against white.
    nonisolated private static func contrastAgainstWhite(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
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
