//
//  RouteChoiceMapContent.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import MapKit

// MARK: - Route Choice Map Content

/// Draws every route option's line, then the selected route's stop markers, then every
/// route's time callout. The selected route's callout draws last.
@MapContentBuilder
func routeChoiceMapContent(
    _ frame: RouteChoiceFrame, legColor: @escaping (RouteLeg) -> Color,
    onSelect: @escaping (RouteOption.ID) -> Void
) -> some MapContent {
    ForEach(frame.routes) { route in
        routeChoiceLines(
            route,
            revealedFraction: route.isSelected
                ? min(frame.revealedFraction, frame.selectedRevealedFraction)
                : frame.revealedFraction,
            legColor: legColor)
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
    // Keyed by route id, so a selection change restyles a callout in place. The frame lists
    // the selected route last, so its callout draws on top.
    ForEach(frame.routes) { route in
        if let callout = route.callout {
            Annotation("", coordinate: callout.coordinate, anchor: callout.corner.unitPoint) {
                RouteCallout(
                    text: callout.timeText, label: callout.labelText,
                    accessibilityText: callout.accessibilityText, corner: callout.corner,
                    isSelected: route.isSelected, isShown: callout.isShown, zoomScale: frame.zoomScale
                ) { onSelect(route.id) }
            }
            .annotationTitles(.hidden)
        }
    }
}

// MARK: - Lines

/// Casings first, then cores, so a later leg's casing never covers an earlier leg's core.
/// Every route draws the same casing and width, selected or not. Only the core color changes.
/// A leg that is still revealing draws flat, and both loops key on `isCased` to insert in order.
@MapContentBuilder
private func routeChoiceLines(
    _ route: RouteChoiceFrame.Route, revealedFraction: Double,
    legColor: @escaping (RouteLeg) -> Color
) -> some MapContent {
    ForEach(keyedLegs(of: route, revealedFraction: revealedFraction), id: \.key) { keyed in
        let leg = keyed.leg
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        if keyed.isCased {
            MapPolyline(coordinates: coords)
                .stroke(legColor(leg).routeCasing, style: RouteLine.casingStyle(for: leg.mode))
        }
    }
    ForEach(keyedLegs(of: route, revealedFraction: revealedFraction), id: \.key) { keyed in
        let leg = keyed.leg
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        if coords.count >= 2 {
            MapPolyline(coordinates: coords)
                .stroke(fadedColor(legColor(leg), strength: route.opacity),
                        style: coreStyle(for: leg))
        }
    }
}

/// Each leg with its overlay key and whether its casing draws. The key changes with `isCased`
/// and `route.isSelected`, so overlays insert in declaration order when either flips.
/// The selected route is last, so its overlays draw on top.
private func keyedLegs(
    of route: RouteChoiceFrame.Route, revealedFraction: Double
) -> [(key: String, leg: RouteLeg, isCased: Bool)] {
    route.legs.map { leg in
        let coords = route.geometry.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
        let isCased = coords.count >= 2 && coords.count == (route.geometry.polylines[leg.id]?.count ?? 0)
        return (key: "\(leg.id)-\(isCased)-\(route.isSelected)", leg: leg, isCased: isCased)
    }
}

/// Walk legs draw at `RouteLine.walkWidth`. Every other leg draws at `RouteLine.coreWidth`.
private func coreStyle(for leg: RouteLeg) -> StrokeStyle {
    leg.mode == .walk ? RouteLine.walkStyle : RouteLine.solidStyle(width: RouteLine.coreWidth)
}

/// A route at the alternate strength draws in `routeAlternate`, which is Slate at 0.3 over Canvas.
/// Above that strength it blends toward `color`, so the selection tween stays smooth.
private func fadedColor(_ color: Color, strength: Double) -> Color {
    let floor = RouteChoiceState.alternateOpacity
    guard strength < 1 else { return color }
    return Color.routeAlternate.mix(with: color, by: max(0, (strength - floor) / (1 - floor)))
}
