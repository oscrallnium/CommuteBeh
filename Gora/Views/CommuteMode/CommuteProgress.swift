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
    /// Corrects the dot onto the actual rail alignment for train legs, whose polyline
    /// is often just a straight chord between stations — the generic road snap below
    /// would reject a real fix taken on a curved stretch of track as "off route".
    private let trackSnapper = TrackSnapper()
    /// Confirmed progress along the current train leg's track. Reset on every leg
    /// switch, since it's only meaningful within one leg's own geometry.
    private var trainProgress: LineProgress?
    /// The in-flight track-snap call. Held so a new fix cancels the previous call
    /// instead of letting two overlapping calls resolve out of order.
    private var trainSnapTask: Task<Void, Never>?
    /// Confirmed within-leg progress for the non-train snap below, so a same-leg
    /// projection that jumps backward past `legProgressJitterToleranceMeters` holds at the
    /// last confirmed point instead of jumping there. Reset on every leg switch, like
    /// `trainProgress`.
    private var lastConfirmedLegProgress: (metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D)?
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
    /// Backward drift below this size on a non-train leg's route-polyline snap is ordinary
    /// GPS jitter — a segment across the road, or a nearby stretch the route loops back
    /// past, briefly reading closer than the real one — not the passenger reversing.
    /// Mirrors `TrackSnapper.progressJitterToleranceMeters`, which guards the same class of
    /// mismatch for train legs.
    private static let legProgressJitterToleranceMeters: CLLocationDistance = 8
    /// How far behind the planned pace before the status flips to `.delayed`.
    private static let lateThresholdSeconds: Double = 180
    /// Used only if a train leg's own distance/time are somehow zero — an MRT-3
    /// interstation average, so dead reckoning has a sane speed to extrapolate with.
    private static let fallbackTrainSpeedMetersPerSecond: Double = 12

    init(result: RouteResult, startedAt: Date) {
        self.result = result
        self.startedAt = startedAt

        legGeometries = result.legs.map { leg in
            var coords = leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            // A leg MKDirections couldn't route has no polyline (see `RouteGeometry`,
            // which draws nothing for it on purpose). Tracking still needs *some* line
            // to project fixes onto, or `closestPoint` reports it as infinitely far and
            // `update(location:)` can never hold it as the current leg — falls back to
            // the straight line between its own stations.
            if coords.count < 2 {
                coords = [
                    CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat,
                                            longitude: leg.fromStation.coordinates.lng),
                    CLLocationCoordinate2D(latitude: leg.toStation.coordinates.lat,
                                            longitude: leg.toStation.coordinates.lng)
                ]
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

    /// Holds a non-train leg's within-leg progress at its last confirmed point when the
    /// new projection lands more than `legProgressJitterToleranceMeters` behind it, so
    /// ordinary GPS jitter picking a nearby-but-wrong segment doesn't teleport the
    /// snapped position (and so the camera following it) backward or sideways along the
    /// route. Always records whatever it returns as the next call's confirmed point,
    /// held or fresh alike.
    private func stabilizedProgress(
        _ candidate: (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D)
    ) -> (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D) {
        guard let last = lastConfirmedLegProgress,
              candidate.metersIntoLeg - last.metersIntoLeg < -Self.legProgressJitterToleranceMeters
        else {
            lastConfirmedLegProgress = (candidate.metersIntoLeg, candidate.coordinate)
            return candidate
        }
        lastConfirmedLegProgress = last
        return (candidate.distanceFromRoute, last.metersIntoLeg, last.coordinate)
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

        if chosenIndex != currentLegIndex {
            trainProgress = nil
            trainSnapTask?.cancel()
            lastConfirmedLegProgress = nil
        }
        currentLegIndex = chosenIndex
        let leg = result.legs[chosenIndex]
        // Train legs get their own, track-aware stabilization from `TrackSnapper` further
        // down; every other mode's route-polyline snap is stabilized here instead.
        let chosen = leg.mode == .train
            ? candidates[chosenIndex]
            : stabilizedProgress(candidates[chosenIndex])
        metersRemainingOnCurrentLeg = max(0, legGeometries[chosenIndex].totalMeters - chosen.metersIntoLeg)
        recomputeOnTimeStatus(now: now, metersIntoLeg: chosen.metersIntoLeg)

        guard leg.mode == .train else {
            trainProgress = nil
            trainSnapTask?.cancel()
            snappedLocation = chosen.distanceFromRoute <= Self.maxSnapDistanceMeters
                ? Coordinates(lat: chosen.coordinate.latitude, lng: chosen.coordinate.longitude)
                : location
            return
        }
        snapToTrack(location: location, leg: leg, now: now)
    }

    /// Runs the train-specific snap on `TrackSnapper`, an actor, and writes the result
    /// back once it lands. Cancels any call still in flight for the previous fix first,
    /// so a burst of fast fixes can't let an older call overwrite a newer one.
    private func snapToTrack(location: Coordinates, leg: RouteLeg, now: Date) {
        trainSnapTask?.cancel()
        let edges = leg.rawSteps.map(\.edge)
        let speed = leg.distanceKm > 0 && leg.effectiveTravelMinutes > 0
            ? leg.distanceKm * 1000 / (leg.effectiveTravelMinutes * 60)
            : Self.fallbackTrainSpeedMetersPerSecond
        let lastConfirmed = trainProgress
        trainSnapTask = Task { [weak self, trackSnapper] in
            let snapResult = await trackSnapper.snap(
                rawCoordinate: location, currentLineEdges: edges, lastConfirmed: lastConfirmed,
                averageInterstationSpeedMetersPerSecond: speed, now: now)
            guard !Task.isCancelled, let self else { return }
            self.trainProgress = snapResult.progress
            self.snappedLocation = snapResult.coordinate
        }
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
