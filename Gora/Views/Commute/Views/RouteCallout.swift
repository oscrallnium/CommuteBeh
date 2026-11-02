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
    static let tail: CGFloat = 8
    static let radius: CGFloat = 12

    /// Smallest body size. Two lines of text fit inside it.
    static func bodySize(isSelected: Bool) -> CGSize {
        isSelected ? CGSize(width: 100, height: 56) : CGSize(width: 84, height: 48)
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

// MARK: - Route Callout

/// Travel-time callout on a route. The tail tip touches the route line. Tapping it selects the route.
struct RouteCallout: View {
    let text: String
    let label: String
    let accessibilityText: String
    let corner: RouteCalloutCorner
    let isSelected: Bool
    let isShown: Bool
    let zoomScale: Double
    let onTap: () -> Void

    private var tail: CGFloat { RouteCalloutMetrics.tail }

    var body: some View {
        Button(action: onTap) {
            lines
                .padding(.horizontal, DesignTokens.Space.m)
                .padding(.vertical, isSelected ? DesignTokens.Space.s : DesignTokens.Space.xs)
                .frame(minWidth: RouteCalloutMetrics.bodySize(isSelected: isSelected).width,
                       minHeight: RouteCalloutMetrics.bodySize(isSelected: isSelected).height)
                .padding(corner.tailInsets(tail))
                .background(RouteCalloutShape(corner: corner, tail: tail).fill(isSelected ? Color.onyx : Color.graphite))
                .overlay(RouteCalloutShape(corner: corner, tail: tail)
                    .stroke(isSelected ? Color.clear : Color.smoke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isShown ? 1 : 0.6, anchor: corner.unitPoint)
        .opacity(isShown ? (isSelected ? 1 : 0.85) : 0)
        .scaleEffect(max(zoomScale, RouteAnnotationScale.floor), anchor: corner.unitPoint)
        .animation(.snappy(duration: 0.25), value: isSelected)
        .animation(isShown ? Animation.spring(response: 0.4, dampingFraction: 0.65) : Animation.easeOut(duration: RouteChoiceState.calloutFadeDuration),
                    value: isShown)
        .animation(.snappy(duration: 0.25), value: zoomScale)
        .allowsHitTesting(isShown)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isSelected ? "" : "Selects this route")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lines: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(isSelected ? DesignTokens.TypeScale.controlLabel : DesignTokens.TypeScale.rowTitle)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.canvas : Color.onyx)
            Text(label)
                .font(isSelected ? DesignTokens.TypeScale.subtitleEmphasis : DesignTokens.TypeScale.meta)
                .foregroundStyle(isSelected ? Color.canvas.opacity(0.7) : Color.slate)
        }
        .lineLimit(1)
    }
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
                     corner: corner, isSelected: selected, isShown: true, zoomScale: 1, onTap: {})
    }
}

#Preview("Route Callout · light") {
    RouteCalloutPreview().preferredColorScheme(.light)
}

#Preview("Route Callout · dark") {
    RouteCalloutPreview().preferredColorScheme(.dark)
}
#endif
