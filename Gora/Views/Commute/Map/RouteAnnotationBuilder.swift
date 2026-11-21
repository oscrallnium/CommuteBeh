//
//  RouteAnnotationBuilder.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import MapKit
import CoreLocation

/// Builds the annotation descriptors of a route. The map orders them by `zPriority`.
enum RouteAnnotationBuilder {

    /// The selected route's stop markers, then every route's time callout.
    static func choiceAnnotations(_ frame: RouteChoiceFrame) -> [MapAnnotationDescriptor] {
        let markers = frame.routes.filter(\.isSelected).flatMap { route in
            route.markers.map { marker in
                MapAnnotationDescriptor(
                    id: "marker-\(route.id)-\(marker.id)", coordinate: marker.coordinate,
                    title: marker.title.isEmpty ? nil : marker.title,
                    content: .stopMarker(routeID: route.id, kind: marker.kind, name: marker.name,
                                         isSelected: route.isSelected),
                    revealAt: revealFraction(of: marker.legID, in: route.geometry),
                    zoomScale: marker.kind == .destination ? scale(for: frame) : 1)
            }
        }
        // A callout keeps its id across selection changes, so a change restyles it in place.
        let callouts = frame.routes.compactMap { route in
            route.callout.map { callout in
                MapAnnotationDescriptor(
                    id: "callout-\(route.id)", coordinate: callout.coordinate, title: nil,
                    content: .callout(routeID: route.id, text: callout.timeText, label: callout.labelText,
                                      accessibilityText: callout.accessibilityText, corner: callout.corner,
                                      isSelected: route.isSelected, isShown: callout.isShown,
                                      schedule: callout.schedule),
                    zoomScale: scale(for: frame))
            }
        }
        return markers + callouts
    }

    private static func scale(for frame: RouteChoiceFrame) -> Double {
        max(frame.zoomScale, RouteAnnotationScale.floor)
    }

    /// The route fraction at which the draw-on reaches the stop that starts `legID`. The destination
    /// has no leg and appears when the draw ends.
    private static func revealFraction(of legID: RouteLeg.ID?, in geometry: RouteGeometry?) -> Double? {
        guard let geometry else { return nil }
        guard let legID else { return 1 }
        return geometry.startFraction(of: legID)
    }

    /// The destination pin and a dot at the start of every leg whose mode differs from the leg before.
    /// A `geometry` makes them appear as the draw-on reaches them. Nil shows them at once.
    static func routeAnnotations(_ result: RouteResult, geometry: RouteGeometry?) -> [MapAnnotationDescriptor] {
        var annotations: [MapAnnotationDescriptor] = []
        if let last = result.legs.last {
            annotations.append(MapAnnotationDescriptor(
                id: "destination", coordinate: legEnd(last, geometry: geometry),
                title: last.line == "ACCESS_WALK" ? nil : last.toStation.shortName,
                content: .destinationPin, revealAt: revealFraction(of: nil, in: geometry)))
        }
        for leg in result.modeChangeLegs {
            annotations.append(MapAnnotationDescriptor(
                id: "transfer-\(leg.id)", coordinate: legStart(leg, geometry: geometry),
                title: nil, content: .transferDot, revealAt: revealFraction(of: leg.id, in: geometry)))
        }
        return annotations
    }

    /// The hollow circle at the start of leg `legIndex`. It marks the current step when Location is off.
    static func stepStart(_ result: RouteResult, legIndex: Int, geometry: RouteGeometry) -> MapAnnotationDescriptor? {
        guard result.legs.indices.contains(legIndex) else { return nil }
        let leg = result.legs[legIndex]
        let start = legStart(leg, geometry: geometry)
        return MapAnnotationDescriptor(id: "stepStart", coordinate: start, title: nil, content: .stepStart)
    }

    /// The first point of the leg's drawn line. A leg with no drawn line starts at its station access point.
    static func legStart(_ leg: RouteLeg, geometry: RouteGeometry?) -> CLLocationCoordinate2D {
        if let line = geometry?.polylines[leg.id], line.count >= 2, let first = line.first { return first }
        return accessCoordinate(leg.fromStation, toward: leg.toStation)
    }

    /// The last point of the leg's drawn line. A leg with no drawn line ends at its station access point.
    static func legEnd(_ leg: RouteLeg, geometry: RouteGeometry?) -> CLLocationCoordinate2D {
        if let line = geometry?.polylines[leg.id], line.count >= 2, let last = line.last { return last }
        return accessCoordinate(leg.toStation, toward: leg.fromStation)
    }

    private static func accessCoordinate(_ station: Station, toward other: Station) -> CLLocationCoordinate2D {
        let point = station.accessPoint(kind: .both, direction: nil, nearestTo: other.coordinates)
        return CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
    }
}
