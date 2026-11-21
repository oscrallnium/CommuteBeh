//
//  RouteCallout.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

// MARK: - Route Callout Corner

/// The corner of the callout frame where the tail tip sits. The tip is the annotation anchor.
enum RouteCalloutCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    private var isTop: Bool { self == .topLeading || self == .topTrailing }
    private var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    /// The tip position inside the callout view, as a fraction of its frame.
    var unitPoint: UnitPoint {
        UnitPoint(x: isLeading ? 0 : 1, y: isTop ? 0 : 1)
    }

    /// Empty room that the tail takes on the two sides that meet at the tip.
    func tailInsets(_ tail: CGFloat) -> EdgeInsets {
        EdgeInsets(top: isTop ? tail : 0, leading: isLeading ? tail : 0,
                   bottom: isTop ? 0 : tail, trailing: isLeading ? 0 : tail)
    }

    /// The frame of a callout of `size` whose tip is at `tip`.
    func frame(tip: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: isLeading ? tip.x : tip.x - size.width, y: isTop ? tip.y : tip.y - size.height,
               width: size.width, height: size.height)
    }

    /// The tip point of `frame`.
    func tipPoint(in frame: CGRect) -> CGPoint {
        CGPoint(x: isLeading ? frame.minX : frame.maxX, y: isTop ? frame.minY : frame.maxY)
    }

    /// `frame` without the tail room.
    func body(of frame: CGRect, tail: CGFloat) -> CGRect {
        CGRect(x: isLeading ? frame.minX + tail : frame.minX, y: isTop ? frame.minY + tail : frame.minY,
               width: frame.width - tail, height: frame.height - tail)
    }
}

// MARK: - Route Callout Metrics

/// Sizes of the callout in points at zoom scale 1. Placement uses the same values as the view.
enum RouteCalloutMetrics {
    static let tail: CGFloat = 10
    static let radius: CGFloat = 16

    /// Smallest body size. Two lines of text fit inside it. Both states share one size.
    static func bodySize(isSelected: Bool) -> CGSize {
        CGSize(width: 132, height: 66)
    }

    /// Body size plus the tail room.
    static func frameSize(isSelected: Bool) -> CGSize {
        let body = bodySize(isSelected: isSelected)
        return CGSize(width: body.width + tail, height: body.height + tail)
    }
}

// MARK: - Route Callout Shape

/// A rounded rectangle with a pointed tail in place of one corner. The tail tip is the frame
/// corner named by `corner`. `tail` is the room the tail takes on each of its two sides.
struct RouteCalloutShape: Shape {
    let corner: RouteCalloutCorner
    let tail: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = corner.body(of: rect, tail: tail)
        let radius = min(RouteCalloutMetrics.radius, body.width / 2, body.height / 2)
        let vertices: [(corner: RouteCalloutCorner, point: CGPoint)] = [
            (.topTrailing, CGPoint(x: body.maxX, y: body.minY)),
            (.bottomTrailing, CGPoint(x: body.maxX, y: body.maxY)),
            (.bottomLeading, CGPoint(x: body.minX, y: body.maxY)),
            (.topLeading, CGPoint(x: body.minX, y: body.minY))
        ]
        var path = Path()
        path.move(to: CGPoint(x: body.midX, y: body.minY))
        for (index, vertex) in vertices.enumerated() {
            let previous = vertices[(index + 3) % 4].point
            let next = vertices[(index + 1) % 4].point
            if vertex.corner == corner {
                path.addLine(to: Self.point(from: vertex.point, toward: previous, by: radius))
                path.addLine(to: corner.tipPoint(in: rect))
                path.addLine(to: Self.point(from: vertex.point, toward: next, by: radius))
            } else {
                path.addArc(tangent1End: vertex.point, tangent2End: next, radius: radius)
            }
        }
        path.closeSubpath()
        return path
    }

    /// The point `distance` away from `origin` on the straight edge toward `target`.
    private static func point(from origin: CGPoint, toward target: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = max(hypot(dx, dy), 1)
        return CGPoint(x: origin.x + dx / length * distance, y: origin.y + dy / length * distance)
    }
}

// MARK: - Route Callout Schedule

/// How a callout of a timetable route looks. A route with no timetable leg has no value.
enum RouteCalloutSchedule: Equatable {
    /// The rider can catch the next trip. A clock symbol precedes the duration.
    case ready
    /// The route is off now. A dashed edge and secondary text show the reason.
    case off
}

// MARK: - Route Callout

/// Travel-time callout on a route. The tail tip touches the route line. Tapping it selects the route.
struct RouteCallout: View {
    let text: String
    let label: String
    let accessibilityText: String
    let corner: RouteCalloutCorner
    let isSelected: Bool
    let isShown: Bool
    var schedule: RouteCalloutSchedule?
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var textSize = Layout.textSize

    private var tail: CGFloat { RouteCalloutMetrics.tail }
    private var shape: RouteCalloutShape { RouteCalloutShape(corner: corner, tail: tail) }
    private var isDark: Bool { colorScheme == .dark }
    private var isOff: Bool { schedule == .off }
    private var restingScale: CGFloat { isSelected ? Layout.selectedScale : Layout.unselectedScale }

    var body: some View {
        Button(action: onTap) {
            lines
                .padding(Layout.contentInsets)
                .frame(minWidth: RouteCalloutMetrics.bodySize(isSelected: isSelected).width,
                       minHeight: RouteCalloutMetrics.bodySize(isSelected: isSelected).height,
                       alignment: .leading)
                .padding(corner.tailInsets(tail))
                .background { surface }
                .animation(colorAnimation, value: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isShown ? restingScale : Layout.hiddenScale, anchor: corner.unitPoint)
        .opacity(isShown ? 1 : 0)
        .animation(scaleAnimation, value: isSelected)
        .animation(isShown ? Animation.spring(response: 0.4, dampingFraction: 0.65) : Animation.easeOut(duration: RouteChoiceState.calloutFadeDuration),
                    value: isShown)
        .allowsHitTesting(isShown)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isSelected ? "" : "Selects this route")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Layout.lineSpacing) {
            primaryLine
                .monospacedDigit()
                .foregroundStyle(isOff ? Color.slate : Color.onyx)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(label)
                    .font(.system(size: textSize, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.calloutSelectedLabel : Color.slate)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var primaryLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            primaryText.typeScale(.statValue)
        } else {
            primaryText.font(.system(size: textSize, weight: .bold))
        }
    }

    @ViewBuilder private var primaryText: some View {
        if schedule == .ready {
            Text("\(Image(systemName: Strings.readySymbol)) \(text)")
        } else {
            Text(text)
        }
    }

    private var surface: some View {
        shape
            .fill(isSelected ? Color.calloutSelected : Color.graphite)
            .background { halo }
            .overlay { outline }
            .shadow(color: shadows.near.color, radius: shadows.near.radius, x: 0, y: shadows.near.y)
            .shadow(color: shadows.far.color, radius: shadows.far.radius, x: 0, y: shadows.far.y)
    }

    private var halo: some View {
        shape
            .stroke(Color.white, lineWidth: Layout.haloWidth * 2)
            .opacity(isSelected && !isDark ? 1 : 0)
    }

    private var outline: some View {
        let width = isSelected ? Layout.ringWidth : Layout.strokeWidth
        let dash = isOff && !isSelected ? Layout.offDash : []
        return shape
            .stroke(isSelected ? Color.selectionRing : Color.smoke,
                    style: StrokeStyle(lineWidth: width * 2, dash: dash))
            .clipShape(shape)
    }

    private var shadows: Layout.ShadowPair {
        switch (isSelected, isDark) {
        case (false, false): Layout.unselectedLightShadows
        case (false, true): Layout.unselectedDarkShadows
        case (true, false): Layout.selectedLightShadows
        case (true, true): Layout.selectedDarkShadows
        }
    }

    private var colorAnimation: Animation {
        reduceMotion ? .easeInOut(duration: Layout.fadeDuration) : .easeInOut(duration: Layout.colorDuration)
    }

    private var scaleAnimation: Animation {
        reduceMotion ? .easeInOut(duration: Layout.fadeDuration) : .spring(duration: Layout.scaleDuration, bounce: Layout.scaleBounce)
    }
}

// MARK: - Strings

private enum Strings {
    static let readySymbol = "clock.fill"
}

// MARK: - Layout

private enum Layout {
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    struct ShadowPair {
        let near: Shadow
        let far: Shadow
    }

    static let textSize: CGFloat = 19
    static let contentInsets = EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 14)
    static let lineSpacing: CGFloat = 1
    static let ringWidth: CGFloat = 2.5
    static let haloWidth: CGFloat = 2.5
    static let strokeWidth: CGFloat = 0.5
    static let offDash: [CGFloat] = [7.5, 5]
    static let selectedScale: CGFloat = 1
    static let unselectedScale: CGFloat = 0.9
    static let hiddenScale: CGFloat = 0.6
    static let scaleDuration: Double = 0.5
    static let scaleBounce: Double = 0.3
    static let colorDuration: Double = 0.22
    static let fadeDuration: Double = 0.15

    private static let ink = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)

    // Radius is half the CSS blur radius.
    static let unselectedLightShadows = ShadowPair(near: Shadow(color: ink.opacity(0.10), radius: 1, y: 1),
                                                   far: Shadow(color: ink.opacity(0.16), radius: 7, y: 6))
    static let unselectedDarkShadows = ShadowPair(near: Shadow(color: .black.opacity(0.35), radius: 1, y: 1),
                                                  far: Shadow(color: .black.opacity(0.45), radius: 7, y: 6))
    static let selectedLightShadows = ShadowPair(near: Shadow(color: ink.opacity(0.12), radius: 2, y: 2),
                                                 far: Shadow(color: ink.opacity(0.22), radius: 12, y: 12))
    static let selectedDarkShadows = ShadowPair(near: Shadow(color: .black.opacity(0.4), radius: 2, y: 2),
                                                far: Shadow(color: .black.opacity(0.55), radius: 12, y: 12))
}

// MARK: - Preview

#if DEBUG
private struct RouteCalloutPreview: View {
    var body: some View {
        ZStack {
            Color(.systemGray4)
            VStack(spacing: DesignTokens.Space.xxl) {
                callout("30 mins", "Fastest", .topLeading, selected: true)
                callout("42 mins", "Cheapest", .bottomTrailing, selected: false)
                callout("38 mins", "Balanced", .topTrailing, selected: false)
            }
        }
    }

    private func callout(_ text: String, _ label: String, _ corner: RouteCalloutCorner, selected: Bool) -> some View {
        RouteCallout(text: text, label: label, accessibilityText: "\(label) route, \(text)",
                     corner: corner, isSelected: selected, isShown: true, onTap: {})
    }
}

#Preview("Route Callout · light") {
    RouteCalloutPreview().preferredColorScheme(.light)
}

#Preview("Route Callout · dark") {
    RouteCalloutPreview().preferredColorScheme(.dark)
}
#endif
