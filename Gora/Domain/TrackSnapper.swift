//
//  TrackSnapper.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/13/26.
//

import CoreLocation
import Foundation

/// Distance travelled along the current line's track, and when that position was
/// last confirmed. `metersFromLineStart` is measured along the flattened polyline of
/// the `currentLineEdges` the caller supplies, in the order given.
struct LineProgress {
    let metersFromLineStart: Double
    let coordinate: Coordinates
    let timestamp: Date
    /// True when this progress came from time-based extrapolation, not a GPS fix.
    let wasDeadReckoned: Bool
}

/// One call's outcome: the coordinate to show, the line progress it implies, and
/// whether the coordinate was pulled onto the track or left as the raw fix.
struct SnapResult {
    let coordinate: Coordinates
    let progress: LineProgress
    let isSnapped: Bool
    let isDeadReckoned: Bool
}

/// Corrects a raw GPS fix to the nearest point on the current train line's track, so a
/// fix that lands beside the rail — the usual case on Metro Manila rail lines — still
/// reads as on the rail on the map.
///
/// Isolated like `TransitGraphEngine`: the caller owns progress state and passes it
/// back in via `lastConfirmed`. The one thing this actor tracks itself is how far
/// into the post-tunnel reconciliation window the last call landed.
actor TrackSnapper {

    /// Beyond this distance from every segment, a fix is off the line for real — a
    /// station forecourt, a parallel road — and must not be pulled onto the track.
    static let maxSnapDistanceMeters: Double = 120
    /// Backward drift below this size is ordinary GPS jitter, not the train reversing.
    static let progressJitterToleranceMeters: Double = 8
    /// Longer than this without a usable fix counts as a tunnel, not a dropped sample.
    static let gpsGapTimeoutSeconds: TimeInterval = 5
    /// How long a reconciling fix takes to fully replace the dead-reckoned position.
    static let reconciliationWindowSeconds: TimeInterval = 6
    /// Ceiling on how long dead reckoning keeps advancing the dot past `gpsGapTimeoutSeconds`
    /// without a real fix. Past this, the position holds instead of compounding schedule-speed
    /// drift indefinitely. Mirrors `CommutePositionResolver.deadReckonCapSeconds`.
    static let deadReckonCapSeconds: TimeInterval = 10

    /// When the current reconciliation stretch began, so blend fraction grows call to
    /// call instead of resetting to zero on every fix. `nil` outside of one.
    private var reconciliationStartedAt: Date?
    /// When the current unbroken dead-reckoning stretch began. `nil` outside of one, and
    /// reset the moment a real fix is used again.
    private var deadReckonStartedAt: Date?

    /// Call on every GPS fix while riding a train leg, and on a timer tick with
    /// `rawCoordinate: nil` while waiting for the next fix — that tick is what lets
    /// dead reckoning advance even though no new fix has arrived.
    func snap(
        rawCoordinate: Coordinates?,
        currentLineEdges: [TransitEdge],
        lastConfirmed: LineProgress?,
        averageInterstationSpeedMetersPerSecond: Double,
        now: Date = .now
    ) async -> SnapResult {
        let geometry = await LineGeometry(edges: currentLineEdges)

        guard let raw = rawCoordinate else {
            return deadReckon(geometry: geometry, lastConfirmed: lastConfirmed,
                               speedMetersPerSecond: averageInterstationSpeedMetersPerSecond, now: now)
        }

        // A real fix landed — the current dead-reckoning stretch, if any, is over.
        deadReckonStartedAt = nil

        guard await geometry.totalMeters > 0 else {
            let fallback = lastConfirmed ?? LineProgress(
                metersFromLineStart: 0, coordinate: raw, timestamp: now, wasDeadReckoned: false)
            return SnapResult(coordinate: raw, progress: fallback, isSnapped: false, isDeadReckoned: false)
        }

        let candidate = geometry.closestPoint(to: raw)

        guard candidate.distanceFromTrack <= Self.maxSnapDistanceMeters else {
            reconciliationStartedAt = nil
            let progress = lastConfirmed ?? LineProgress(
                metersFromLineStart: candidate.metersFromStart, coordinate: candidate.coordinate,
                timestamp: now, wasDeadReckoned: false)
            return SnapResult(coordinate: raw, progress: progress, isSnapped: false, isDeadReckoned: false)
        }

        guard let lastConfirmed else {
            reconciliationStartedAt = nil
            let progress = LineProgress(metersFromLineStart: candidate.metersFromStart,
                                         coordinate: candidate.coordinate, timestamp: now, wasDeadReckoned: false)
            return SnapResult(coordinate: candidate.coordinate, progress: progress, isSnapped: true, isDeadReckoned: false)
        }

        if lastConfirmed.wasDeadReckoned {
            return reconcile(candidate: candidate, lastConfirmed: lastConfirmed, now: now)
        }

        let delta = candidate.metersFromStart - lastConfirmed.metersFromLineStart
        guard delta >= -Self.progressJitterToleranceMeters else {
            return SnapResult(coordinate: lastConfirmed.coordinate, progress: lastConfirmed,
                               isSnapped: true, isDeadReckoned: false)
        }

        let progress = LineProgress(metersFromLineStart: candidate.metersFromStart,
                                     coordinate: candidate.coordinate, timestamp: now, wasDeadReckoned: false)
        return SnapResult(coordinate: candidate.coordinate, progress: progress, isSnapped: true, isDeadReckoned: false)
    }

    /// Advances progress by elapsed time × line speed once a gap exceeds
    /// `gpsGapTimeoutSeconds`, capped at the line's end and at `deadReckonCapSeconds` of
    /// unconfirmed advancement. Below the timeout, holds the last confirmed point rather
    /// than treating a single missed fix as a tunnel.
    private func deadReckon(
        geometry: LineGeometry,
        lastConfirmed: LineProgress?,
        speedMetersPerSecond: Double,
        now: Date
    ) -> SnapResult {
        guard let lastConfirmed else {
            let coordinate = geometry.coords.first ?? Coordinates(lat: 0, lng: 0)
            let fallback = LineProgress(metersFromLineStart: 0, coordinate: coordinate, timestamp: now, wasDeadReckoned: false)
            return SnapResult(coordinate: coordinate, progress: fallback, isSnapped: false, isDeadReckoned: false)
        }

        let gap = now.timeIntervalSince(lastConfirmed.timestamp)
        guard gap > Self.gpsGapTimeoutSeconds else {
            return SnapResult(coordinate: lastConfirmed.coordinate, progress: lastConfirmed,
                               isSnapped: true, isDeadReckoned: false)
        }

        let startedAt = deadReckonStartedAt ?? now
        deadReckonStartedAt = startedAt
        guard now.timeIntervalSince(startedAt) <= Self.deadReckonCapSeconds else {
            return SnapResult(coordinate: lastConfirmed.coordinate, progress: lastConfirmed,
                               isSnapped: true, isDeadReckoned: true)
        }

        let advancedMeters = min(geometry.totalMeters,
                                  lastConfirmed.metersFromLineStart + gap * max(0, speedMetersPerSecond))
        let coordinate = geometry.coordinate(atMeters: advancedMeters) ?? lastConfirmed.coordinate
        let progress = LineProgress(metersFromLineStart: advancedMeters, coordinate: coordinate,
                                     timestamp: now, wasDeadReckoned: true)
        reconciliationStartedAt = nil
        return SnapResult(coordinate: coordinate, progress: progress, isSnapped: true, isDeadReckoned: true)
    }

    /// Blends from the dead-reckoned position toward a fresh raw-derived candidate over
    /// `reconciliationWindowSeconds`, so GPS reacquiring after a tunnel eases the dot
    /// back onto the fix instead of jumping it there in one frame.
    private func reconcile(candidate: LineGeometry.Projection, lastConfirmed: LineProgress, now: Date) -> SnapResult {
        let startedAt = reconciliationStartedAt ?? now
        reconciliationStartedAt = startedAt

        let elapsed = now.timeIntervalSince(startedAt)
        let fraction = min(1, max(0, elapsed / Self.reconciliationWindowSeconds))

        let blendedMeters = lastConfirmed.metersFromLineStart
            + fraction * (candidate.metersFromStart - lastConfirmed.metersFromLineStart)
        let blendedCoordinate = Coordinates(
            lat: lastConfirmed.coordinate.lat + fraction * (candidate.coordinate.lat - lastConfirmed.coordinate.lat),
            lng: lastConfirmed.coordinate.lng + fraction * (candidate.coordinate.lng - lastConfirmed.coordinate.lng))

        let stillReconciling = fraction < 1
        if !stillReconciling { reconciliationStartedAt = nil }

        let progress = LineProgress(metersFromLineStart: blendedMeters, coordinate: blendedCoordinate,
                                     timestamp: now, wasDeadReckoned: stillReconciling)
        return SnapResult(coordinate: blendedCoordinate, progress: progress, isSnapped: true, isDeadReckoned: stillReconciling)
    }
}

/// A line's track flattened into one ordered polyline with cumulative distance, so
/// "closest point" and "point at distance X" are lookups instead of a re-walk.
///
/// Drops the first coordinate of every edge after the first — it duplicates the
/// previous edge's last point, the shared station junction.
private struct LineGeometry {
    struct Projection {
        let distanceFromTrack: CLLocationDistance
        let metersFromStart: Double
        let coordinate: Coordinates
    }

    let coords: [Coordinates]
    let cumulativeMeters: [Double]
    var totalMeters: Double { cumulativeMeters.last ?? 0 }

    init(edges: [TransitEdge]) {
        var flattened: [Coordinates] = []
        for (index, edge) in edges.enumerated() {
            let points = index == 0 ? edge.polylineCoordinates : Array(edge.polylineCoordinates.dropFirst())
            flattened.append(contentsOf: points)
        }
        coords = flattened

        guard coords.count >= 2 else {
            cumulativeMeters = coords.isEmpty ? [] : [0]
            return
        }
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            let segment = CLLocation(latitude: coords[i - 1].lat, longitude: coords[i - 1].lng)
                .distance(from: CLLocation(latitude: coords[i].lat, longitude: coords[i].lng))
            cumulative.append(cumulative[i - 1] + segment)
        }
        cumulativeMeters = cumulative
    }

    /// Perpendicular projection onto the closest segment, clamped to that segment's
    /// own two endpoints so a fix near a station can't project past it onto the next.
    func closestPoint(to point: Coordinates) -> Projection {
        guard coords.count >= 2 else {
            return Projection(distanceFromTrack: .greatestFiniteMagnitude, metersFromStart: 0, coordinate: point)
        }

        var best = Projection(distanceFromTrack: .greatestFiniteMagnitude, metersFromStart: 0, coordinate: point)
        for i in 0..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let dx = b.lng - a.lng
            let dy = b.lat - a.lat
            let lengthSquared = dx * dx + dy * dy
            let t: Double = lengthSquared > 0
                ? max(0, min(1, ((point.lng - a.lng) * dx + (point.lat - a.lat) * dy) / lengthSquared))
                : 0
            let projected = Coordinates(lat: a.lat + t * dy, lng: a.lng + t * dx)
            let distance = CLLocation(latitude: point.lat, longitude: point.lng)
                .distance(from: CLLocation(latitude: projected.lat, longitude: projected.lng))

            if distance < best.distanceFromTrack {
                let metersFromStart = cumulativeMeters[i] + t * (cumulativeMeters[i + 1] - cumulativeMeters[i])
                best = Projection(distanceFromTrack: distance, metersFromStart: metersFromStart, coordinate: projected)
            }
        }
        return best
    }

    /// Coordinate at a given distance along the line, interpolated between the two
    /// nearest vertices. Clamps to the line's start or end past its bounds.
    func coordinate(atMeters meters: Double) -> Coordinates? {
        guard coords.count >= 2 else { return coords.first }
        let clamped = max(0, min(totalMeters, meters))
        for i in 0..<(cumulativeMeters.count - 1) {
            guard clamped <= cumulativeMeters[i + 1] else { continue }
            let span = cumulativeMeters[i + 1] - cumulativeMeters[i]
            let t = span > 0 ? (clamped - cumulativeMeters[i]) / span : 0
            let a = coords[i], b = coords[i + 1]
            return Coordinates(lat: a.lat + t * (b.lat - a.lat), lng: a.lng + t * (b.lng - a.lng))
        }
        return coords.last
    }
}
