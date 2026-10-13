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
    /// Backs `revealedCoordinates`, which walks this to find where a fraction lands.
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
    /// ever changing. `sharedHintPolyline` in this file draws a shared stretch differently
    /// for exactly this reason; see its doc comment.
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

    /// See `sharedWithNextMask`'s doc comment. Only meaningful for `coords` exactly equal to
    /// `polylines[legID]` — the full, untrimmed polyline this was measured against; callers
    /// with a partial (still-revealing) array should not use this.
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

    /// `leg`'s polyline truncated to the leading `fraction` of the whole route's length,
    /// measured cumulatively across every leg in origin-to-destination order. Draws the
    /// route on progressively: empty before the reveal reaches this leg, the full
    /// polyline once it has passed, and an interpolated partial segment in between.
    func revealedCoordinates(leg legID: RouteLeg.ID, fraction: Double) -> [CLLocationCoordinate2D] {
        guard let coords = polylines[legID], coords.count >= 2, totalLength > 0 else {
            return polylines[legID] ?? []
        }
        let cumulative = legCumulativeDistances[legID] ?? []
        let legLength = cumulative.last ?? 0
        let start = legStartOffsets[legID] ?? 0
        let revealed = max(0, min(totalLength, fraction * totalLength)) - start

        if revealed <= 0 { return [] }
        if revealed >= legLength { return coords }

        for i in 0..<(cumulative.count - 1) {
            guard cumulative[i + 1] >= revealed else { continue }
            let segStart = cumulative[i]
            let segLength = cumulative[i + 1] - segStart
            let t = segLength > 0 ? (revealed - segStart) / segLength : 0
            let a = coords[i], b = coords[i + 1]
            let point = CLLocationCoordinate2D(
                latitude: a.latitude + t * (b.latitude - a.latitude),
                longitude: a.longitude + t * (b.longitude - a.longitude))
            return Array(coords[0...i]) + [point]
        }
        return coords
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

/// A single flat stroke, core color only — no casing. Every polyline whose coordinates can
/// change from one `body` evaluation to the next must draw this way, not via
/// `casedRoutePolyline`: `MapPolyline` wraps an immutable `MKPolyline`, so a coordinate
/// change swaps the whole `MKOverlay` rather than moving a point in place, and each swap
/// redraws asynchronously on its own schedule. Two overlays sharing a coordinate source that
/// changes every frame race each other's redraw and visibly desync mid-animation — the wider
/// casing trailing or leading the narrower core, or (with several legs animating at once,
/// each pair racing independently) one leg's line flickering where it runs near another's. A
/// single overlay has nothing to race.
@MapContentBuilder
private func flatRoutePolyline(
    coordinates: [CLLocationCoordinate2D], mode: TransportMode,
    width: CGFloat = RouteLine.coreWidth, color: Color? = nil
) -> some MapContent {
    MapPolyline(coordinates: coordinates)
        .stroke(color ?? mode.color, style: routeCoreStyle(mode: mode, width: width))
}

/// Walking legs draw as dots and every other mode as a solid line of `width`.
private func routeCoreStyle(mode: TransportMode, width: CGFloat) -> StrokeStyle {
    mode == .walk ? RouteLine.walk : RouteLine.solidStyle(width: width)
}

/// Draws a canvas-colored casing beneath the core, in `color`, so the route stays legible over
/// roads, water, and park fills. Walking legs have no casing.
///
/// Only for a polyline whose coordinates are settled for this `body` evaluation and the ones
/// immediately around it — see `flatRoutePolyline`'s doc comment for why an animating one
/// must use that instead.
@MapContentBuilder
private func casedRoutePolyline(coordinates: [CLLocationCoordinate2D], mode: TransportMode, color: Color) -> some MapContent {
    if mode != .walk {
        MapPolyline(coordinates: coordinates)
            .stroke(Color.canvas, style: RouteLine.solidStyle(width: RouteLine.coreWidth + 2 * RouteLine.casing))
    }
    flatRoutePolyline(coordinates: coordinates, mode: mode, color: color)
}

/// Splits `coords` into contiguous runs classified by the parallel `mask` (`true`/`false`
/// must alternate at the same indices in both), each run including the point just past its
/// end so adjacent runs still join without a gap — the same technique `splitPolyline` uses
/// for its behind/ahead halves.
private func splitByMask(
    _ coords: [CLLocationCoordinate2D], mask: [Bool]
) -> [(isShared: Bool, coords: [CLLocationCoordinate2D])] {
    guard coords.count == mask.count, coords.count >= 2 else {
        return coords.count >= 2 ? [(false, coords)] : []
    }
    var runs: [(isShared: Bool, coords: [CLLocationCoordinate2D])] = []
    var runStart = 0
    for i in 1..<coords.count where mask[i] != mask[i - 1] {
        runs.append((mask[i - 1], Array(coords[runStart...i])))
        runStart = i
    }
    runs.append((mask[runStart], Array(coords[runStart...])))
    return runs
}

/// Shifts each point of `coords` `meters` to the right of the local direction of travel,
/// in flat lat/lng space — accurate enough over the few metres `sharedHintPolyline` needs.
/// Same latitude-scale correction `arcCoordinates` uses for its own perpendicular offset.
private func offsetCoordinates(
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

/// A thin dashed line in the leg color, offset a few metres to the side of `coordinates`,
/// for a stretch where this leg's own path isn't drawn because the next leg's polyline
/// already occupies the same space (see `RouteGeometry.sharedWithNextMask`). Offsetting
/// keeps it from re-creating the exact near-coincident-overlay conflict this exists to
/// avoid, while still showing the passenger that a leg continues alongside the one on top.
private let sharedHintOffsetMeters: Double = 5

@MapContentBuilder
private func sharedHintPolyline(coordinates: [CLLocationCoordinate2D], color: Color) -> some MapContent {
    MapPolyline(coordinates: offsetCoordinates(coordinates, metersToTheRight: sharedHintOffsetMeters))
        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
}

/// `casedRoutePolyline`, except a stretch marked `true` in `mask` draws as
/// `sharedHintPolyline` instead — see `RouteGeometry.sharedWithNextMask`'s doc comment for
/// why. `mask` must be `nil` or the same length as `coordinates`; anything else falls back
/// to drawing the whole polyline cased, unsplit.
@MapContentBuilder
private func maskedRoutePolyline(
    coordinates: [CLLocationCoordinate2D], mask: [Bool]?, mode: TransportMode, color: Color
) -> some MapContent {
    if let mask, mask.count == coordinates.count {
        ForEach(Array(splitByMask(coordinates, mask: mask).enumerated()), id: \.offset) { _, run in
            if run.isShared {
                sharedHintPolyline(coordinates: run.coords, color: color)
            } else {
                casedRoutePolyline(coordinates: run.coords, mode: mode, color: color)
            }
        }
    } else {
        casedRoutePolyline(coordinates: coordinates, mode: mode, color: color)
    }
}

/// One leg's polyline exactly as `RouteGeometry` computed it — the non-commuting route
/// preview, and every leg still ahead of the passenger in Commute Mode. A leg
/// MKDirections couldn't route has no geometry and draws nothing on purpose; never
/// fall back to connecting its endpoints here (`currentLegPolylineContent` below is
/// where that rule is different, and why).
///
/// `isAnimating` is true only for the pre-commute reveal, while this leg's own coordinates
/// are still growing toward their full length (`ContentView` compares the revealed count
/// against the full count, since legs finish revealing at different times). True draws a
/// single flat stroke instead of the cased one — see `flatRoutePolyline`'s doc comment.
///
/// `sharedMask` is `RouteGeometry.sharedWithNextMask(leg:)`, only meaningful (and only ever
/// passed) once `coords` is the full, untrimmed polyline it was measured against.
@MapContentBuilder
func routePolylineContent(
    leg: RouteLeg, coords: [CLLocationCoordinate2D], isAnimating: Bool, color: Color, sharedMask: [Bool]?
) -> some MapContent {
    if coords.count < 2 {
        EmptyMapContent()
    } else if isAnimating {
        flatRoutePolyline(coordinates: coords, mode: leg.mode, color: color)
    } else {
        maskedRoutePolyline(coordinates: coords, mask: sharedMask, mode: leg.mode, color: color)
    }
}

/// A straight dotted line from `passenger` to `start`, the first point of the walk line drawn
/// ahead. Draws nothing when the two points are less than 2 m apart.
@MapContentBuilder
private func walkConnector(
    from passenger: CLLocationCoordinate2D, to start: CLLocationCoordinate2D?, mode: TransportMode, color: Color
) -> some MapContent {
    if let start,
       CLLocation(latitude: passenger.latitude, longitude: passenger.longitude)
        .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude)) >= 2 {
        flatRoutePolyline(coordinates: [passenger, start], mode: mode, width: RouteLine.currentWidth, color: color)
    }
}

/// A leg the passenger already finished, drawn in the faint color. Flat, with no casing.
@MapContentBuilder
func completedLegPolylineContent(leg: RouteLeg, coords: [CLLocationCoordinate2D]) -> some MapContent {
    if coords.count >= 2 {
        flatRoutePolyline(coordinates: coords, mode: leg.mode, color: .faint)
    }
}

/// The leg the passenger is currently on. Only the portion still ahead is drawn. Falls back
/// to a straight guide line when the leg has no real geometry.
///
/// Always flat: the cut follows the live passenger position. See `Commute-Views.md`.
@MapContentBuilder
func currentLegPolylineContent(
    leg: RouteLeg, coords: [CLLocationCoordinate2D], passenger: CLLocationCoordinate2D?,
    geometry: RouteGeometry, walkGridStep: CLLocationDistance?, color: Color
) -> some MapContent {
    let hasRealGeometry = coords.count >= 2
    let gridIndex: Int? = {
        guard leg.mode == .walk, hasRealGeometry, let passenger, let walkGridStep else { return nil }
        return geometry.gridIndexAhead(leg: leg.id, passenger: passenger, step: walkGridStep)
    }()
    if let gridIndex, let walkGridStep {
        // One overlay per chunk of ground. A chunk keeps its coordinates while the passenger
        // advances, so no overlay swaps and no two overlays draw the same stretch.
        let first = max(0, gridIndex - 1) / RouteGeometry.walkChunkSteps
        ForEach(first..<max(first + 1, geometry.walkChunkCount(leg: leg.id, step: walkGridStep)), id: \.self) { index in
            if let chunk = geometry.walkChunk(leg: leg.id, index: index, step: walkGridStep), chunk.count >= 2 {
                flatRoutePolyline(coordinates: chunk, mode: leg.mode, width: RouteLine.currentWidth, color: color)
            }
        }
        if let passenger {
            walkConnector(from: passenger, to: splitPolyline(coords, at: passenger).ahead.first, mode: leg.mode, color: color)
        }
    } else {
        let baseCoords: [CLLocationCoordinate2D] = hasRealGeometry ? coords : [
            CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat, longitude: leg.fromStation.coordinates.lng),
            CLLocationCoordinate2D(latitude: leg.toStation.coordinates.lat, longitude: leg.toStation.coordinates.lng)
        ]
        let ahead = splitPolyline(baseCoords, at: passenger).ahead
        if ahead.count >= 2 {
            flatRoutePolyline(coordinates: ahead, mode: leg.mode, width: RouteLine.currentWidth, color: color)
        }
        if leg.mode == .walk, hasRealGeometry, let passenger {
            walkConnector(from: passenger, to: ahead.first, mode: leg.mode, color: color)
        }
    }
}
