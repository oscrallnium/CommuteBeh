//
//  StationAccessConnector.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/4/26.
//

import SwiftUI
import MapKit

/// Points along a quadratic Bezier curve bowed perpendicular to the straight line between
/// `start` and `end`, approximated in flat lat/lng space (accurate enough over the tens of
/// metres a station's doors sit from its centroid).
private func arcCoordinates(
    from start: Coordinates,
    to end: Coordinates,
    bowFraction: Double = 0.35,
    samples: Int = 24
) -> [CLLocationCoordinate2D] {
    let scale = cos(((start.lat + end.lat) / 2) * .pi / 180)
    let dLat = end.lat - start.lat
    let dLng = end.lng - start.lng
    let midLat = (start.lat + end.lat) / 2
    let midLng = (start.lng + end.lng) / 2

    // Perpendicular to (dLng·scale, dLat), rotated 90° so the curve bows to one side
    // rather than doubling back on the straight chord.
    let controlLat = midLat + (dLng * scale) * bowFraction
    let controlLng = midLng - (dLat / max(scale, 0.0001)) * bowFraction

    return (0...samples).map { i in
        let t = Double(i) / Double(samples)
        let u = 1 - t
        let lat = u * u * start.lat + 2 * u * t * controlLat + t * t * end.lat
        let lng = u * u * start.lng + 2 * u * t * controlLng + t * t * end.lng
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// Compass bearing (0° = north, clockwise) from `a` to `b`.
func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
    let dLng = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLng) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
    let degrees = atan2(y, x) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

/// The thin solid curved connector from a station's nearest access point to its routing
/// centroid, with an arrow tip at the centroid. Nil when the access point and centroid share
/// the same coordinate, because there is nothing to connect.
private func stationAccessConnector(
    station: Station, nearestTo other: Coordinates
) -> (line: RouteLineDescriptor, tip: MapAnnotationDescriptor)? {
    let access = station.accessPoint(kind: .both, direction: nil, nearestTo: other)
    let centroid = station.coordinates
    guard abs(access.lat - centroid.lat) > 1e-7 || abs(access.lng - centroid.lng) > 1e-7 else { return nil }
    let arc = arcCoordinates(from: access, to: centroid)
    guard arc.count >= 2 else { return nil }
    let tip = arc[arc.count - 1]
    return (
        RouteLineDescriptor(
            id: "connector-\(station.id)", coordinates: arc,
            stroke: LineStroke(color: .black, style: RouteLine.connectorStyle)),
        MapAnnotationDescriptor(
            id: "connector-tip-\(station.id)", coordinate: tip, title: nil,
            content: .connectorTip(bearing: bearingDegrees(from: arc[arc.count - 2], to: tip))))
}

/// One end of a leg: a station and the coordinate its access point is chosen nearest to.
private struct ConnectorEnd: Identifiable {
    let station: Station
    let other: Coordinates
    var id: StationID { station.id }
}

/// Each station in `legs` once, in leg order. A transfer station ends one leg and starts the next.
private func uniqueConnectorEnds(_ legs: ArraySlice<RouteLeg>) -> [ConnectorEnd] {
    var seen = Set<StationID>()
    return legs.flatMap { leg in
        [ConnectorEnd(station: leg.fromStation, other: leg.toStation.coordinates),
         ConnectorEnd(station: leg.toStation, other: leg.fromStation.coordinates)]
    }.filter { seen.insert($0.id).inserted }
}

/// The connector of each station across `legs`, once per station.
func stationAccessConnectors(
    legs: ArraySlice<RouteLeg>
) -> (lines: [RouteLineDescriptor], tips: [MapAnnotationDescriptor]) {
    let connectors = uniqueConnectorEnds(legs).compactMap {
        stationAccessConnector(station: $0.station, nearestTo: $0.other)
    }
    return (connectors.map(\.line), connectors.map(\.tip))
}
