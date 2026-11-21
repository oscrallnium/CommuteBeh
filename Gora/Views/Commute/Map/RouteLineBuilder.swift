//
//  RouteLineBuilder.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit
import CoreLocation

/// Where the passenger is in the route. Decides how each leg draws.
enum LegProgress {
    /// Route choice or a route preview. Every leg draws in full and draws on from the start.
    case preview
    /// Commute Mode. The legs behind the passenger fade, the current leg shows what is left.
    case commuting(currentIndex: Int, passenger: CLLocationCoordinate2D?)
    /// Commute Mode with Location off. Every leg draws in full: finished legs fade, the current leg is thicker.
    case manual(currentIndex: Int)
}

/// Builds the line descriptors of a route. Each leg has one casing and one core overlay for the
/// whole draw-on. Both carry the same reveal span, so they grow together.
enum RouteLineBuilder {

    private enum SharedHint {
        static let offsetMeters = 5.0
        static let opacity = 0.6
        static let style = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4])
    }

    /// Shortest gap that draws a walk connector.
    private static let connectorMinimumMeters: CLLocationDistance = 2

    // MARK: Route choice

    /// Every option's casings, then its cores. The frame lists the selected route last, so it draws on top.
    /// Every route draws the same casing and width. Only the core color changes with selection.
    static func choiceLines(_ frame: RouteChoiceFrame, legColor: (RouteLeg) -> Color) -> [RouteLineDescriptor] {
        frame.routes.flatMap { route -> [RouteLineDescriptor] in
            let drawn = route.legs.compactMap { leg -> (leg: RouteLeg, coords: [CLLocationCoordinate2D])? in
                guard let coords = route.geometry.polylines[leg.id], coords.count >= 2 else { return nil }
                return (leg, coords)
            }
            let casings = drawn.map { item in
                RouteLineDescriptor(
                    id: "\(route.id)-\(item.leg.id)-casing", coordinates: item.coords,
                    stroke: LineStroke(color: legColor(item.leg).routeCasing,
                                       style: RouteLine.casingStyle(for: item.leg.mode)),
                    reveal: route.geometry.revealSpan(leg: item.leg.id))
            }
            let cores = drawn.map { item in
                RouteLineDescriptor(
                    id: "\(route.id)-\(item.leg.id)-core", coordinates: item.coords,
                    stroke: LineStroke(color: fadedColor(legColor(item.leg), strength: route.opacity),
                                       style: coreStyle(for: item.leg.mode, width: RouteLine.coreWidth)),
                    reveal: route.geometry.revealSpan(leg: item.leg.id))
            }
            return casings + cores
        }
    }

    /// A route at the alternate strength draws in `routeAlternate`, which is Slate at 0.3 over Canvas.
    /// Above that strength it blends toward `color`, so the selection tween stays smooth.
    private static func fadedColor(_ color: Color, strength: Double) -> Color {
        let floor = RouteChoiceState.alternateOpacity
        guard strength < 1 else { return color }
        return Color.routeAlternate.mix(with: color, by: max(0, (strength - floor) / (1 - floor)))
    }

    // MARK: Single route

    /// One descriptor list per leg, in leg order.
    static func routeLines(
        _ result: RouteResult, geometry: RouteGeometry, progress: LegProgress, legColor: (RouteLeg) -> Color
    ) -> [RouteLineDescriptor] {
        result.legs.enumerated().flatMap { index, leg -> [RouteLineDescriptor] in
            let coords = geometry.polylines[leg.id] ?? []
            switch progress {
            case .preview:
                return settledLines(leg, coords: coords, geometry: geometry, color: legColor(leg), drawsOn: true)
            case .commuting(let currentIndex, let passenger):
                if index < currentIndex { return completedLines(leg, coords: coords) }
                if index == currentIndex {
                    return currentLines(leg, coords: coords, passenger: passenger, color: legColor(leg))
                }
                return settledLines(leg, coords: coords, geometry: geometry, color: legColor(leg), drawsOn: false)
            case .manual(let currentIndex):
                let emphasis = StepEmphasis(isCurrent: index == currentIndex, isDone: index < currentIndex)
                return settledLines(leg, coords: coords, geometry: geometry, color: legColor(leg),
                                    drawsOn: false, emphasis: emphasis)
            }
        }
    }

    /// How a leg draws when Location is off. The stroke tweens when the step changes.
    private struct StepEmphasis {
        let isCurrent: Bool
        let isDone: Bool

        var opacity: Double { isDone ? RouteLine.doneOpacity : 1 }

        func coreWidth(for mode: TransportMode) -> CGFloat {
            switch (mode == .walk, isCurrent) {
            case (true, true): RouteLine.currentWalkWidth
            case (true, false): RouteLine.walkWidth
            case (false, true): RouteLine.currentWidth
            case (false, false): RouteLine.coreWidth
            }
        }
    }

    /// The leg's polyline exactly as `RouteGeometry` computed it. A stretch that runs along the
    /// next leg draws as a thin dashed hint beside it. A leg that MKDirections could not route
    /// has no geometry and draws nothing.
    private static func settledLines(
        _ leg: RouteLeg, coords: [CLLocationCoordinate2D], geometry: RouteGeometry, color: Color, drawsOn: Bool,
        emphasis: StepEmphasis? = nil
    ) -> [RouteLineDescriptor] {
        let opacity = emphasis?.opacity ?? 1
        let coreWidth = emphasis?.coreWidth(for: leg.mode) ?? (leg.mode == .walk ? RouteLine.walkWidth : RouteLine.coreWidth)
        let isTweened = emphasis != nil
        let runs = splitByMask(count: coords.count, mask: geometry.sharedWithNextMask(leg: leg.id) ?? [])
        return runs.enumerated().flatMap { index, run -> [RouteLineDescriptor] in
            let slice = Array(coords[run.range])
            let reveal = drawsOn ? geometry.revealSpan(leg: leg.id, points: run.range) : nil
            if run.isShared {
                return [RouteLineDescriptor(
                    id: "\(leg.id)-hint-\(index)",
                    coordinates: offsetCoordinates(slice, metersToTheRight: SharedHint.offsetMeters),
                    stroke: LineStroke(color: color.mapOpacity(SharedHint.opacity * opacity), style: SharedHint.style,
                                       animatesChange: isTweened),
                    reveal: reveal)]
            }
            return [
                RouteLineDescriptor(
                    id: "\(leg.id)-casing-\(index)", coordinates: slice,
                    stroke: LineStroke(color: opacity < 1 ? color.routeCasing.mapOpacity(opacity) : color.routeCasing,
                                       style: RouteLine.solidStyle(width: coreWidth + 2 * RouteLine.casing),
                                       animatesChange: isTweened),
                    reveal: reveal),
                RouteLineDescriptor(
                    id: "\(leg.id)-core-\(index)", coordinates: slice,
                    stroke: LineStroke(color: opacity < 1 ? color.mapOpacity(opacity) : color,
                                       style: RouteLine.solidStyle(width: coreWidth), animatesChange: isTweened),
                    reveal: reveal)
            ]
        }
    }

    /// A leg the passenger already finished, in the faint color. Flat, with no casing.
    private static func completedLines(_ leg: RouteLeg, coords: [CLLocationCoordinate2D]) -> [RouteLineDescriptor] {
        guard coords.count >= 2 else { return [] }
        return [RouteLineDescriptor(
            id: "\(leg.id)-done", coordinates: coords,
            stroke: LineStroke(color: .faint, style: coreStyle(for: leg.mode, width: RouteLine.coreWidth)))]
    }

    /// The leg the passenger rides now. Only the part ahead draws, and it draws flat because the
    /// cut follows the passenger. A leg with no geometry falls back to a straight guide line.
    /// A walk leg also gets a thin solid connector from the passenger to the line.
    private static func currentLines(
        _ leg: RouteLeg, coords: [CLLocationCoordinate2D], passenger: CLLocationCoordinate2D?, color: Color
    ) -> [RouteLineDescriptor] {
        let hasRealGeometry = coords.count >= 2
        let base: [CLLocationCoordinate2D] = hasRealGeometry ? coords : [
            CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat, longitude: leg.fromStation.coordinates.lng),
            CLLocationCoordinate2D(latitude: leg.toStation.coordinates.lat, longitude: leg.toStation.coordinates.lng)
        ]
        let ahead = splitPolyline(base, at: passenger).ahead
        var lines: [RouteLineDescriptor] = []
        if ahead.count >= 2 {
            lines.append(RouteLineDescriptor(
                id: "\(leg.id)-current", coordinates: ahead,
                stroke: LineStroke(color: color, style: coreStyle(for: leg.mode, width: RouteLine.currentWidth))))
        }
        if leg.mode == .walk, hasRealGeometry, let passenger, let start = ahead.first,
           CLLocation(latitude: passenger.latitude, longitude: passenger.longitude)
            .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude)) >= connectorMinimumMeters {
            lines.append(RouteLineDescriptor(
                id: "\(leg.id)-connector", coordinates: [passenger, start],
                stroke: LineStroke(color: color, style: RouteLine.connectorStyle)))
        }
        return lines
    }

    /// Walk legs draw at `RouteLine.walkWidth`. Every other leg draws at `width`.
    private static func coreStyle(for mode: TransportMode, width: CGFloat) -> StrokeStyle {
        mode == .walk ? RouteLine.walkStyle : RouteLine.solidStyle(width: width)
    }
}
