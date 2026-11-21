//
//  RoutePolylineRendering.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/29/26.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Route Geometry

/// Map-ready coordinates for one `RouteResult`: the polyline per leg, plus the bounding box
/// of every polyline and its endpoints. Computed once per route, because refined walk legs
/// hold hundreds of points and `ContentView.body` re-evaluates on every animation frame.
struct RouteGeometry {
    /// Keyed by `RouteLeg.id`. A leg MKDirections couldn't route maps to an empty array —
    /// it draws nothing on purpose; never fall back to connecting its endpoints.
    let polylines: [RouteLeg.ID: [CLLocationCoordinate2D]]
    /// Per leg, in order: id, point count, first and last coordinate. `matches` compares these,
    /// so a leg whose polyline is replaced under the same id invalidates the cache.
    private let legSignatures: [LegSignature]

    let minLat: CLLocationDegrees
    let maxLat: CLLocationDegrees
    let minLng: CLLocationDegrees
    let maxLng: CLLocationDegrees

    /// Cumulative distance (metres) to each point in a leg's polyline, `[0, …, legLength]`.
    /// Backs `revealSpan`, which turns it into the share of the route a polyline covers.
    let legCumulativeDistances: [RouteLeg.ID: [Double]]
    /// Distance (metres) along the whole route, in leg order, at which each leg starts.
    private let legStartOffsets: [RouteLeg.ID: Double]
    /// Sum of every leg's polyline length, in metres. Zero when no leg has real geometry.
    private let totalLength: Double

    /// Per point on a leg's polyline: true where that point sits within
    /// `overlapThresholdMeters` of the *next* leg's polyline — a walk-to-stop leg that
    /// runs along the same street the next leg's bus travels, for example. `nil` for a
    /// route's last leg, which has no next leg to compare against.
    ///
    /// Two overlays occupying near-identical screen space compete for the same pixels on
    /// every render pass, with no guaranteed winner — visible as a flicker with zero data
    /// ever changing. `RouteLineBuilder` draws a shared stretch as an offset dashed hint for
    /// exactly this reason.
    private let sharedWithNextMask: [RouteLeg.ID: [Bool]]
    private static let overlapThresholdMeters: CLLocationDistance = 10

    /// `nil` for a route with no legs — nothing to draw and nothing to frame.
    init?(_ result: RouteResult) {
        guard !result.legs.isEmpty else { return nil }

        var polylines: [RouteLeg.ID: [CLLocationCoordinate2D]] = [:]
        polylines.reserveCapacity(result.legs.count)
        var legCumulativeDistances: [RouteLeg.ID: [Double]] = [:]
        var legStartOffsets: [RouteLeg.ID: Double] = [:]
        var runningLength: Double = 0

        var minLat = CLLocationDegrees.greatestFiniteMagnitude
        var maxLat = -CLLocationDegrees.greatestFiniteMagnitude
        var minLng = CLLocationDegrees.greatestFiniteMagnitude
        var maxLng = -CLLocationDegrees.greatestFiniteMagnitude

        func extend(lat: CLLocationDegrees, lng: CLLocationDegrees) {
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLng = min(minLng, lng); maxLng = max(maxLng, lng)
        }

        for leg in result.legs {
            let coords = leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            polylines[leg.id] = coords
            for coord in coords { extend(lat: coord.latitude, lng: coord.longitude) }
            // Endpoints go into the box but never into the drawn line: a walk leg
            // MKDirections couldn't route has no geometry at all, and framing on polylines
            // alone would push the origin (or destination) pin off screen.
            extend(lat: leg.fromStation.coordinates.lat, lng: leg.fromStation.coordinates.lng)
            extend(lat: leg.toStation.coordinates.lat,   lng: leg.toStation.coordinates.lng)

            var cumulative: [Double] = []
            if coords.count >= 2 {
                cumulative.reserveCapacity(coords.count)
                cumulative.append(0)
                var running: Double = 0
                for i in 0..<(coords.count - 1) {
                    running += CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                        .distance(from: CLLocation(latitude: coords[i + 1].latitude, longitude: coords[i + 1].longitude))
                    cumulative.append(running)
                }
            }
            legCumulativeDistances[leg.id] = cumulative
            legStartOffsets[leg.id] = runningLength
            runningLength += cumulative.last ?? 0
        }

        var sharedWithNextMask: [RouteLeg.ID: [Bool]] = [:]
        for i in 0..<max(0, result.legs.count - 1) {
            let legID = result.legs[i].id
            guard let coords = polylines[legID], let nextCoords = polylines[result.legs[i + 1].id],
                  coords.count >= 2, nextCoords.count >= 2
            else { continue }
            sharedWithNextMask[legID] = coords.map {
                Self.minDistance(from: $0, toPolyline: nextCoords) <= Self.overlapThresholdMeters
            }
        }

        self.polylines = polylines
        self.legSignatures = result.legs.map(LegSignature.init)
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
        self.legCumulativeDistances = legCumulativeDistances
        self.legStartOffsets = legStartOffsets
        self.totalLength = runningLength
        self.sharedWithNextMask = sharedWithNextMask
    }

    /// True when every leg has the same id, polyline point count, first coordinate, and last
    /// coordinate as when this was built. It never compares whole coordinate arrays.
    func matches(_ result: RouteResult) -> Bool {
        legSignatures.elementsEqual(result.legs.lazy.map(LegSignature.init))
    }

    private struct LegSignature: Equatable {
        let id: RouteLeg.ID
        let pointCount: Int
        let first: [Double]
        let last: [Double]

        init(_ leg: RouteLeg) {
            id = leg.id
            pointCount = leg.polylineCoordinates.count
            first = leg.polylineCoordinates.first.map { [$0.lat, $0.lng] } ?? []
            last = leg.polylineCoordinates.last.map { [$0.lat, $0.lng] } ?? []
        }
    }

    /// See `sharedWithNextMask`'s doc comment. Only meaningful for `polylines[legID]`, the full,
    /// untrimmed polyline this was measured against.
    func sharedWithNextMask(leg legID: RouteLeg.ID) -> [Bool]? {
        sharedWithNextMask[legID]
    }

    /// Shortest distance from `point` to any segment of `coords`.
    private static func minDistance(
        from point: CLLocationCoordinate2D, toPolyline coords: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        let target = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var best = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let dLng = b.longitude - a.longitude, dLat = b.latitude - a.latitude
            let lenSq = dLng * dLng + dLat * dLat
            let t: Double = lenSq > 0
                ? max(0, min(1, ((point.longitude - a.longitude) * dLng + (point.latitude - a.latitude) * dLat) / lenSq))
                : 0
            let proj = CLLocationCoordinate2D(latitude: a.latitude + t * dLat, longitude: a.longitude + t * dLng)
            best = min(best, target.distance(from: CLLocation(latitude: proj.latitude, longitude: proj.longitude)))
        }
        return best
    }

    /// The route fraction, 0...1, at which `leg` starts. Nil when the route has no length.
    func startFraction(of legID: RouteLeg.ID) -> Double? {
        guard totalLength > 0, let start = legStartOffsets[legID] else { return nil }
        return start / totalLength
    }

    /// The share of the whole route's length, measured across every leg in origin-to-destination
    /// order, that `leg`'s points in `points` cover. `points` defaults to the whole leg.
    /// Nil when the route or the leg has no length, which draws in full.
    func revealSpan(leg legID: RouteLeg.ID, points: ClosedRange<Int>? = nil) -> RevealSpan? {
        guard totalLength > 0, let cumulative = legCumulativeDistances[legID], cumulative.count >= 2 else {
            return nil
        }
        let range = points ?? 0...(cumulative.count - 1)
        guard cumulative.indices.contains(range.lowerBound), cumulative.indices.contains(range.upperBound)
        else { return nil }
        let start = legStartOffsets[legID] ?? 0
        return RevealSpan(start: (start + cumulative[range.lowerBound]) / totalLength,
                          end: (start + cumulative[range.upperBound]) / totalLength)
    }
}

// MARK: - Live Route Polyline (Commute Mode)

/// Projects `passenger` onto `coords` and returns (behind, ahead): all coords up to
/// and including the projected point, and all coords from it onward. Both halves share
/// the same projected point as their endpoint/startpoint, so they join seamlessly.
/// Returns `([], coords)` when `passenger` is nil or there are fewer than two coords.
func splitPolyline(
    _ coords: [CLLocationCoordinate2D],
    at passenger: CLLocationCoordinate2D?
) -> (behind: [CLLocationCoordinate2D], ahead: [CLLocationCoordinate2D]) {
    guard let passenger, coords.count >= 2 else { return ([], coords) }
    let passengerLoc = CLLocation(latitude: passenger.latitude, longitude: passenger.longitude)

    var bestIndex = 0
    var bestDist = CLLocationDistance.greatestFiniteMagnitude
    var bestPoint = coords[0]

    for i in 0..<(coords.count - 1) {
        let a = coords[i], b = coords[i + 1]
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        let lenSq = dx * dx + dy * dy
        let t: Double = lenSq > 0
            ? max(0, min(1, ((passenger.longitude - a.longitude) * dx + (passenger.latitude - a.latitude) * dy) / lenSq))
            : 0
        let proj = CLLocationCoordinate2D(latitude: a.latitude + t * dy, longitude: a.longitude + t * dx)
        let d = passengerLoc.distance(from: CLLocation(latitude: proj.latitude, longitude: proj.longitude))
        if d < bestDist { bestDist = d; bestIndex = i; bestPoint = proj }
    }

    let behind = Array(coords[0...bestIndex]) + [bestPoint]
    let ahead  = [bestPoint] + Array(coords[(bestIndex + 1)...])
    return (behind, ahead)
}

/// Compass bearing of the route from the point nearest `passenger` to the point
/// `lookAheadMeters` further along `coords`. `nil` when `coords` has no usable direction ahead.
func routeHeading(
    along coords: [CLLocationCoordinate2D],
    at passenger: CLLocationCoordinate2D?,
    lookAheadMeters: CLLocationDistance = 40
) -> Double? {
    let ahead = splitPolyline(coords, at: passenger).ahead
    guard ahead.count >= 2 else { return nil }
    var remaining = lookAheadMeters
    var target = ahead[ahead.count - 1]
    for i in 1..<ahead.count {
        let a = ahead[i - 1], b = ahead[i]
        let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        if length >= remaining {
            let t = length > 0 ? remaining / length : 0
            target = CLLocationCoordinate2D(
                latitude: a.latitude + t * (b.latitude - a.latitude),
                longitude: a.longitude + t * (b.longitude - a.longitude))
            break
        }
        remaining -= length
    }
    let origin = CLLocation(latitude: ahead[0].latitude, longitude: ahead[0].longitude)
    guard origin.distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) > 0.5
    else { return nil }
    return bearingDegrees(from: ahead[0], to: target)
}

/// Splits a polyline of `count` points into contiguous runs classified by the parallel `mask`
/// (`true`/`false` must alternate at the same indices in both). Each run includes the point
/// just past its end so adjacent runs still join without a gap, the same technique
/// `splitPolyline` uses for its behind/ahead halves. A `mask` of another length gives one run.
func splitByMask(count: Int, mask: [Bool]) -> [(isShared: Bool, range: ClosedRange<Int>)] {
    guard count >= 2 else { return [] }
    guard count == mask.count else { return [(false, 0...(count - 1))] }
    var runs: [(isShared: Bool, range: ClosedRange<Int>)] = []
    var runStart = 0
    for i in 1..<count where mask[i] != mask[i - 1] {
        runs.append((mask[i - 1], runStart...i))
        runStart = i
    }
    runs.append((mask[runStart], runStart...(count - 1)))
    return runs
}

/// Shifts each point of `coords` `meters` to the right of the local direction of travel,
/// in flat lat/lng space — accurate enough over the few metres a shared-segment hint needs.
/// Same latitude-scale correction `arcCoordinates` uses for its own perpendicular offset.
func offsetCoordinates(
    _ coords: [CLLocationCoordinate2D], metersToTheRight meters: Double
) -> [CLLocationCoordinate2D] {
    let metersPerDegreeLat = 111_320.0
    return coords.indices.map { i in
        let a = coords[max(0, i - 1)]
        let b = coords[min(coords.count - 1, i + 1)]
        let dLat = b.latitude - a.latitude, dLng = b.longitude - a.longitude
        let len = (dLat * dLat + dLng * dLng).squareRoot()
        guard len > 0 else { return coords[i] }
        let metersPerDegreeLng = max(metersPerDegreeLat * cos(coords[i].latitude * .pi / 180), 1)
        // Perpendicular to (dLng, dLat), rotated so positive `meters` reads as "to the right".
        return CLLocationCoordinate2D(
            latitude: coords[i].latitude - (dLng / len) * meters / metersPerDegreeLat,
            longitude: coords[i].longitude + (dLat / len) * meters / metersPerDegreeLng)
    }
}
