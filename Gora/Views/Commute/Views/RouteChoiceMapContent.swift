//
//  RouteChoiceMapContent.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import MapKit

// MARK: - Route Choice Map Content

/// Draws every route option's line, then the selected route's stop markers and time bubble,
/// so the selected route's markers and bubble draw on top of every line.
@MapContentBuilder
func routeChoiceMapContent(
    _ frame: RouteChoiceFrame, legColor: @escaping (RouteLeg) -> Color,
    onSelect: @escaping (RouteOption.ID) -> Void
) -> some MapContent {
    ForEach(frame.routes) { route in
        routeChoiceLines(
            route, revealedFraction: frame.revealedFraction, zoomScale: frame.zoomScale, legColor: legColor)
    }
    ForEach(frame.routes.filter(\.isSelected)) { route in
        ForEach(route.markers) { marker in
            Annotation(
                route.isSelected ? marker.title : "", coordinate: marker.coordinate,
                anchor: marker.kind == .destination ? .bottom : .center
            ) {
                RouteStopMarker(marker: marker, isSelected: route.isSelected, zoomScale: frame.zoomScale) {
                    onSelect(route.id)
                }
            }
        }
    }
    // One bubble annotation outside any per-route loop, so a new selection moves it.
    if let route = frame.routes.last(where: \.isSelected), let bubble = route.bubble {
        Annotation("", coordinate: bubble.coordinate, anchor: .center) {
            RouteTimeBubble(
                text: bubble.timeText, accessibilityText: bubble.accessibilityText,
                isSelected: route.isSelected, isShown: bubble.isShown,
                zoomScale: frame.zoomScale
            ) { onSelect(route.id) }
        }
        .annotationTitles(.hidden)
    }
}

// MARK: - Lines

/// Casings first, then cores, so a later leg's casing never covers an earlier leg's core.
/// Casing draws only for the selected route at rest. A route that is revealing or tweening
/// draws flat, because casing and core redraw out of step when their coordinates change.
/// Both loops key on `isCased`, so a casing change re-inserts casing and core in that order.
@MapContentBuilder
private func routeChoiceLines(
    _ route: RouteChoiceFrame.Route, revealedFraction: Double, zoomScale: Double,
    legColor: @escaping (RouteLeg) -> Color
) -> some MapContent {
    ForEach(keyedLegs(of: route, revealedFraction: revealedFraction), id: \.key) { keyed in
        let leg = keyed.leg
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        if keyed.isCased {
            MapPolyline(coordinates: coords)
                .stroke(Color.canvas, style: RouteLine.solidStyle(width: route.width + 2 * RouteLine.casing))
        }
    }
    ForEach(keyedLegs(of: route, revealedFraction: revealedFraction), id: \.key) { keyed in
        let leg = keyed.leg
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        if coords.count >= 2 {
            MapPolyline(coordinates: coords)
                .stroke(legColor(leg).opacity(route.opacity),
                        style: coreStyle(for: leg, in: route, zoomScale: zoomScale))
        }
    }
}

/// Each leg with its overlay key and whether its casing draws. The key changes with
/// `isCased`, so both loops insert fresh overlays in declaration order when that flips.
private func keyedLegs(
    of route: RouteChoiceFrame.Route, revealedFraction: Double
) -> [(key: String, leg: RouteLeg, isCased: Bool)] {
    route.legs.map { leg in
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        let isCased = route.isSelected && !route.isFlat && leg.mode != .walk
            && coords.count >= 2 && coords.count == (route.geometry.polylines[leg.id]?.count ?? 0)
        return (key: "\(leg.id)-\(isCased)", leg: leg, isCased: isCased)
    }
}

/// Walk legs of the selected route draw as dots, scaled by `zoomScale`. Every other leg
/// draws solid.
private func coreStyle(for leg: RouteLeg, in route: RouteChoiceFrame.Route, zoomScale: Double) -> StrokeStyle {
    if route.isSelected, leg.mode == .walk {
        return RouteLine.walkStyle(scale: zoomScale)
    }
    return RouteLine.solidStyle(width: route.width)
}
