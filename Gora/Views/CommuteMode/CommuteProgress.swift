//
//  CommuteProgress.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import Foundation
import CoreLocation

/// Live progress through a `RouteResult` once the passenger has committed to it —
/// which leg they're actually on, how far is left on it, and whether they're keeping
/// pace with the plan. Driven by GPS fixes (`update(location:)`) plus a light timer for
/// the on-time figure alone, since elapsed time keeps moving between fixes.
@Observable
final class CommuteProgressEngine {
    enum OnTimeStatus {
        case onTime
        case delayed
    }

    private(set) var currentLegIndex = 0
    private(set) var metersRemainingOnCurrentLeg: CLLocationDistance = 0
    private(set) var onTimeStatus: OnTimeStatus = .onTime
    private(set) var minutesBehindSchedule: Double = 0
    /// The passenger's live fix, projected onto the current leg's polyline — what the
    /// camera and progress figures track instead of the raw GPS point. A fix a few
    /// metres off the road one moment and back on it the next (ordinary urban GPS
    /// noise) reads as "on the road" throughout instead of hopping to whichever
    /// parallel street the noise happened to land nearest. `nil` before the first fix.
    ///
    /// Only actually snapped within `maxSnapDistanceMeters` of the route — past that,
    /// the passenger has plausibly left it for real (a detour, a wrong turn), and
    /// showing the raw fix is more honest than pinning them to a road they're not on.
    private(set) var snappedLocation: Coordinates?

    let result: RouteResult
    private let startedAt: Date
    private let legGeometries: [LegGeometry]
    /// Planned elapsed seconds (from `startedAt`) at which the passenger should reach
    /// the *start* of each leg — the running sum of every prior leg's planned duration.
    private let plannedElapsedAtLegStart: [Double]

    /// A leg once it's stopped moving day to day: its polyline reduced to cumulative
    /// distance along it, so "how far into this leg" is a lookup, not a re-walk.
    private struct LegGeometry {
        let coords: [CLLocationCoordinate2D]
        /// `cumulativeMeters[i]` = distance travelled along `coords[0...i]`.
        let cumulativeMeters: [CLLocationDistance]
        var totalMeters: CLLocationDistance { cumulativeMeters.last ?? 0 }
    }

    /// A leg's polyline projects flush against the road/track it follows, so a mismatch
    /// this size only ever means the passenger has actually moved to a different leg —
    /// not that the same leg's own fix jittered. Keeps the current leg from flapping
    /// between an access-walk leg and the ride leg it hands off to, whose endpoints can
    /// sit within a few metres of each other at a station's access point.
    private static let legSwitchMarginMeters: CLLocationDistance = 20
    /// Beyond this distance from the chosen leg's polyline, a fix is treated as
    /// genuinely off-route rather than road-noise — wide enough to absorb ordinary
    /// urban GPS error (often 10-30 m, occasionally more between tall buildings)
    /// without being so wide that a real wrong turn still reads as "on the road".
    private static let maxSnapDistanceMeters: CLLocationDistance = 75
    /// How far behind the planned pace before the status flips to `.delayed`.
    private static let lateThresholdSeconds: Double = 180

    init(result: RouteResult, startedAt: Date) {
        self.result = result
        self.startedAt = startedAt

        legGeometries = result.legs.map { leg in
            let coords = leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            guard coords.count >= 2 else {
                return LegGeometry(coords: coords, cumulativeMeters: coords.isEmpty ? [] : [0])
            }
            var cumulative: [CLLocationDistance] = [0]
            cumulative.reserveCapacity(coords.count)
            for i in 1..<coords.count {
                let segment = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                    .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
                cumulative.append(cumulative[i - 1] + segment)
            }
            return LegGeometry(coords: coords, cumulativeMeters: cumulative)
        }

        var elapsed: Double = 0
        plannedElapsedAtLegStart = result.legs.map { leg in
            let atStart = elapsed
            elapsed += leg.effectiveTravelMinutes * 60
            return atStart
        }

        metersRemainingOnCurrentLeg = legGeometries.first?.totalMeters ?? 0
    }

    /// Closest point anywhere along `geo`'s polyline to `point`, as a distance off the
    /// route and how far along the route that point sits — mirrors the projection
    /// `LoopCreatorView.roadPointsNear(_:road:within:)` already uses for the same
    /// "closest point on a polyline" problem, minus that function's run-bucketing (a
    /// route leg's polyline doesn't loop back over itself the way a recorded road can).
    private func closestPoint(on geo: LegGeometry, to point: CLLocationCoordinate2D)
        -> (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D) {
        guard geo.coords.count >= 2 else { return (.greatestFiniteMagnitude, 0, point) }

        var best: (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D) =
            (.greatestFiniteMagnitude, 0, point)

        for i in 0..<(geo.coords.count - 1) {
            let a = geo.coords[i], b = geo.coords[i + 1]
            let dx = b.longitude - a.longitude
            let dy = b.latitude - a.latitude
            let lenSq = dx * dx + dy * dy
            let t: Double = lenSq > 0
                ? max(0, min(1, ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lenSq))
                : 0
            let projected = CLLocationCoordinate2D(latitude: a.latitude + t * dy,
                                                    longitude: a.longitude + t * dx)
            let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: CLLocation(latitude: projected.latitude, longitude: projected.longitude))

            if distance < best.distanceFromRoute {
                let metersIntoLeg = geo.cumulativeMeters[i] + t * (geo.cumulativeMeters[i + 1] - geo.cumulativeMeters[i])
                best = (distance, metersIntoLeg, projected)
            }
        }
        return best
    }

    /// Call on every new GPS fix while commuting.
    func update(location: Coordinates, now: Date = .now) {
        guard !legGeometries.isEmpty else { return }
        let point = CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng)
        let candidates = legGeometries.map { closestPoint(on: $0, to: point) }

        guard let globalBestIndex = candidates.indices.min(by: { candidates[$0].distanceFromRoute < candidates[$1].distanceFromRoute })
        else { return }

        let chosenIndex: Int
        if globalBestIndex == currentLegIndex
            || candidates[currentLegIndex].distanceFromRoute - candidates[globalBestIndex].distanceFromRoute
                > Self.legSwitchMarginMeters {
            chosenIndex = globalBestIndex
        } else {
            chosenIndex = currentLegIndex
        }

        currentLegIndex = chosenIndex
        let chosen = candidates[chosenIndex]
        metersRemainingOnCurrentLeg = max(0, legGeometries[chosenIndex].totalMeters - chosen.metersIntoLeg)
        snappedLocation = chosen.distanceFromRoute <= Self.maxSnapDistanceMeters
            ? Coordinates(lat: chosen.coordinate.latitude, lng: chosen.coordinate.longitude)
            : location
        recomputeOnTimeStatus(now: now, metersIntoLeg: chosen.metersIntoLeg)
    }

    /// The on-time half of `update`, split out so it can also be re-run on a plain timer
    /// — elapsed time keeps moving even when GPS fixes are sparse (standing on a
    /// platform between fixes shouldn't freeze "how late am I").
    func recomputeOnTimeStatus(now: Date, metersIntoLeg: CLLocationDistance? = nil) {
        guard result.legs.indices.contains(currentLegIndex) else { return }
        let leg = result.legs[currentLegIndex]
        let legTotalMeters = legGeometries[currentLegIndex].totalMeters

        let fractionAlongLeg: Double
        if let metersIntoLeg, legTotalMeters > 0 {
            fractionAlongLeg = min(1, max(0, metersIntoLeg / legTotalMeters))
        } else {
            let remaining = legTotalMeters > 0 ? metersRemainingOnCurrentLeg / legTotalMeters : 0
            fractionAlongLeg = min(1, max(0, 1 - remaining))
        }

        let plannedElapsedAtPosition = plannedElapsedAtLegStart[currentLegIndex]
            + fractionAlongLeg * leg.effectiveTravelMinutes * 60
        let actualElapsed = now.timeIntervalSince(startedAt)
        let deltaSeconds = actualElapsed - plannedElapsedAtPosition

        minutesBehindSchedule = max(0, deltaSeconds / 60)
        onTimeStatus = deltaSeconds > Self.lateThresholdSeconds ? .delayed : .onTime
    }
}
