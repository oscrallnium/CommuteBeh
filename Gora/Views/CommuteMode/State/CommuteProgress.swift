//
//  CommuteProgress.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import Foundation
import CoreLocation

/// Live progress through a `RouteResult` once the passenger has committed to it —
/// current leg, distance left, on-time status. Driven by GPS fixes via
/// `update(location:)`. See `CommuteMode-State.md`.
@Observable
final class CommuteProgressEngine {
    enum OnTimeStatus {
        case onTime
        case delayed
    }

    private(set) var currentLegIndex = 0
    private(set) var metersRemainingOnCurrentLeg: CLLocationDistance = 0
    private(set) var metersIntoCurrentLeg: CLLocationDistance = 0
    private(set) var onTimeStatus: OnTimeStatus = .onTime
    private(set) var minutesBehindSchedule: Double = 0
    /// The passenger's live fix, projected onto the current leg's polyline — what the
    /// camera and progress figures track instead of the raw GPS point. `nil` before
    /// the first fix. See `CommuteMode-State.md`.
    private(set) var snappedLocation: Coordinates?
    /// Raw fix's distance off the current leg's polyline, unstabilized — unlike
    /// `metersRemainingOnCurrentLeg`, which holds through jitter. Feeds
    /// `CommuteRerouteMonitor`'s deviation gate. See `CommuteMode-State.md`.
    private(set) var currentLegOffRouteMeters: CLLocationDistance = 0
    /// Compass bearing of the current leg's polyline at the point nearest the raw fix —
    /// the direction a passenger on-route would be facing there. Feeds
    /// `CommuteRerouteMonitor`'s bearing gate.
    private(set) var currentLegAheadBearing: CLLocationDirection = 0

    private(set) var result: RouteResult
    private let startedAt: Date
    private var legGeometries: [LegGeometry]
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
    /// Confirmed within-leg progress for the non-train snap below. Reset on every leg
    /// switch, like `trainProgress`. See `CommuteMode-State.md`.
    private var lastConfirmedLegProgress: (metersIntoLeg: CLLocationDistance, coordinate: CLLocationCoordinate2D)?
    /// Planned elapsed seconds (from `startedAt`) at which the passenger should reach
    /// the *start* of each leg — the running sum of every prior leg's planned duration.
    private var plannedElapsedAtLegStart: [Double]

    /// A leg once it's stopped moving day to day: its polyline reduced to cumulative
    /// distance along it, so "how far into this leg" is a lookup, not a re-walk.
    private struct LegGeometry {
        let coords: [CLLocationCoordinate2D]
        /// `cumulativeMeters[i]` = distance travelled along `coords[0...i]`.
        let cumulativeMeters: [CLLocationDistance]
        var totalMeters: CLLocationDistance { cumulativeMeters.last ?? 0 }
    }

    /// How much closer a different leg's polyline must be before the engine actually
    /// switches to it. See `CommuteMode-State.md`.
    private static let legSwitchMarginMeters: CLLocationDistance = 20
    /// A walk leg ends when the fix is this close to its last point, so the next leg starts
    /// at the station even while the walk and the ride lie at the same distance.
    private static let walkArrivalRadiusMeters: CLLocationDistance = 50
    /// Beyond this distance from the chosen leg's polyline, a fix is treated as
    /// genuinely off-route rather than road-noise. See `CommuteMode-State.md`.
    private static let maxSnapDistanceMeters: CLLocationDistance = 75
    /// Backward drift below this size on a non-train leg's snap is ordinary GPS jitter,
    /// not the passenger reversing. See `CommuteMode-State.md`.
    private static let legProgressJitterToleranceMeters: CLLocationDistance = 8
    /// How far behind the planned pace before the status flips to `.delayed`.
    private static let lateThresholdSeconds: Double = 180
    /// Used only if a train leg's own distance/time are somehow zero — an MRT-3
    /// interstation average, so dead reckoning has a sane speed to extrapolate with.
    private static let fallbackTrainSpeedMetersPerSecond: Double = 12

    init(result: RouteResult, startedAt: Date) {
        self.result = result
        self.startedAt = startedAt
        legGeometries = Self.buildLegGeometries(for: result)
        plannedElapsedAtLegStart = Self.buildPlannedElapsedAtLegStart(for: result)
        metersRemainingOnCurrentLeg = legGeometries.first?.totalMeters ?? 0
    }

    /// One leg's polyline reduced to cumulative distance along it. Shared by `init` and
    /// `applyReroute(_:)`, which rebuilds this for a route patched mid-ride.
    private static func buildLegGeometries(for result: RouteResult) -> [LegGeometry] {
        result.legs.map { leg in
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
    }

    /// Running sum of each leg's planned duration. Shared by `init` and `applyReroute(_:)`.
    private static func buildPlannedElapsedAtLegStart(for result: RouteResult) -> [Double] {
        var elapsed: Double = 0
        return result.legs.map { leg in
            let atStart = elapsed
            elapsed += leg.effectiveTravelMinutes * 60
            return atStart
        }
    }

    /// Share of the current leg already covered, from 0 to 1.
    var fractionAlongCurrentLeg: Double {
        guard legGeometries.indices.contains(currentLegIndex),
              legGeometries[currentLegIndex].totalMeters > 0 else { return 0 }
        return min(1, max(0, metersIntoCurrentLeg / legGeometries[currentLegIndex].totalMeters))
    }

    /// Planned seconds already covered at the current position, summed over the whole route.
    private var plannedElapsedSeconds: Double {
        guard result.legs.indices.contains(currentLegIndex) else { return 0 }
        return plannedElapsedAtLegStart[currentLegIndex]
            + fractionAlongCurrentLeg * result.legs[currentLegIndex].effectiveTravelMinutes * 60
    }

    private var totalPlannedSeconds: Double {
        result.legs.reduce(0) { $0 + $1.effectiveTravelMinutes * 60 }
    }

    /// Route progress from 0 to 1, weighted by planned minutes per leg.
    var progressFraction: Double {
        let total = totalPlannedSeconds
        return total > 0 ? min(1, max(0, plannedElapsedSeconds / total)) : 0
    }

    /// Planned seconds left on the route from the current position.
    var plannedSecondsRemaining: Double {
        max(0, totalPlannedSeconds - plannedElapsedSeconds)
    }

    /// Adopts a route patched mid-ride — currently only `CommuteRerouter`, which rewrites
    /// the current walk leg's geometry and shifts every later leg's ETA. Keeps `startedAt`
    /// and `currentLegIndex`: the leg count and order are unchanged, only this leg's own
    /// geometry and the schedule downstream of it. Clears the same state a normal leg
    /// switch clears, since the current leg's geometry is effectively new.
    func applyReroute(_ newResult: RouteResult) {
        result = newResult
        legGeometries = Self.buildLegGeometries(for: newResult)
        plannedElapsedAtLegStart = Self.buildPlannedElapsedAtLegStart(for: newResult)
        lastConfirmedLegProgress = nil
        trainProgress = nil
        trainSnapTask?.cancel()
    }

    /// Closest point anywhere along `geo`'s polyline to `point`, as a distance off the
    /// route, how far along the route that point sits, and the route's own bearing at
    /// that point. See `CommuteMode-State.md`.
    private func closestPoint(on geo: LegGeometry, to point: CLLocationCoordinate2D)
        -> (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance,
            coordinate: CLLocationCoordinate2D, aheadBearing: CLLocationDirection) {
        guard geo.coords.count >= 2 else { return (.greatestFiniteMagnitude, 0, point, 0) }

        var best: (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance,
                    coordinate: CLLocationCoordinate2D, aheadBearing: CLLocationDirection) =
            (.greatestFiniteMagnitude, 0, point, 0)

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
                best = (distance, metersIntoLeg, projected, Self.bearingDegrees(from: a, to: b))
            }
        }
        return best
    }

    /// Compass bearing, degrees clockwise from true north, from `a` to `b`. Own copy
    /// deliberately kept private to this file — the codebase already has one private
    /// bearing helper per call site rather than a shared one (see `StopInsertionPreview`,
    /// `RoutePolylineRendering`).
    private static func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Holds a non-train leg's within-leg progress at its last confirmed point when a
    /// new projection jumps backward past the jitter tolerance. See
    /// `CommuteMode-State.md`.
    private func stabilizedProgress(
        _ candidate: (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance,
                       coordinate: CLLocationCoordinate2D, aheadBearing: CLLocationDirection)
    ) -> (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance,
          coordinate: CLLocationCoordinate2D, aheadBearing: CLLocationDirection) {
        guard let last = lastConfirmedLegProgress,
              candidate.metersIntoLeg - last.metersIntoLeg < -Self.legProgressJitterToleranceMeters
        else {
            lastConfirmedLegProgress = (candidate.metersIntoLeg, candidate.coordinate)
            return candidate
        }
        lastConfirmedLegProgress = last
        return (candidate.distanceFromRoute, last.metersIntoLeg, last.coordinate, candidate.aheadBearing)
    }

    /// Call on every new GPS fix while commuting.
    func update(location: Coordinates, now: Date = .now) {
        guard !legGeometries.isEmpty else { return }
        let point = CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng)
        let candidates = legGeometries.map { closestPoint(on: $0, to: point) }

        guard let globalBestIndex = candidates.indices.min(by: { candidates[$0].distanceFromRoute < candidates[$1].distanceFromRoute })
        else { return }

        var chosenIndex: Int
        if globalBestIndex == currentLegIndex
            || candidates[currentLegIndex].distanceFromRoute - candidates[globalBestIndex].distanceFromRoute
                > Self.legSwitchMarginMeters {
            chosenIndex = globalBestIndex
        } else {
            chosenIndex = currentLegIndex
        }
        if hasFinishedWalk(legIndex: chosenIndex, at: point) {
            chosenIndex += 1
        }

        if chosenIndex != currentLegIndex {
            trainProgress = nil
            trainSnapTask?.cancel()
            lastConfirmedLegProgress = nil
        }
        currentLegIndex = chosenIndex
        let leg = result.legs[chosenIndex]
        // Raw, unstabilized — `CommuteRerouteMonitor` needs the actual fix's deviation,
        // not the held-back value `stabilizedProgress` may report below.
        currentLegOffRouteMeters = candidates[chosenIndex].distanceFromRoute
        currentLegAheadBearing = candidates[chosenIndex].aheadBearing
        if leg.mode == .walk {
            applyWalkProgress(candidates[chosenIndex], location: location, now: now)
            return
        }
        // Train legs get their own, track-aware stabilization from `TrackSnapper` further
        // down; every other mode's route-polyline snap is stabilized here instead.
        let chosen = leg.mode == .train
            ? candidates[chosenIndex]
            : stabilizedProgress(candidates[chosenIndex])
        metersRemainingOnCurrentLeg = max(0, legGeometries[chosenIndex].totalMeters - chosen.metersIntoLeg)
        metersIntoCurrentLeg = chosen.metersIntoLeg
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

    /// True when leg `index` is a walk, a later leg exists, and `point` is within
    /// `walkArrivalRadiusMeters` of the walk's last point.
    private func hasFinishedWalk(legIndex index: Int, at point: CLLocationCoordinate2D) -> Bool {
        guard result.legs[index].mode == .walk,
              result.legs.indices.contains(index + 1),
              let end = legGeometries[index].coords.last else { return false }
        let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        return distance <= Self.walkArrivalRadiusMeters
    }

    /// Walk-leg update: progress follows the raw projection, backward movement included,
    /// and the dot sits on the raw fix. Leaves `lastConfirmedLegProgress` untouched.
    private func applyWalkProgress(
        _ candidate: (distanceFromRoute: CLLocationDistance, metersIntoLeg: CLLocationDistance,
                       coordinate: CLLocationCoordinate2D, aheadBearing: CLLocationDirection),
        location: Coordinates, now: Date
    ) {
        metersRemainingOnCurrentLeg = max(0, legGeometries[currentLegIndex].totalMeters - candidate.metersIntoLeg)
        metersIntoCurrentLeg = candidate.metersIntoLeg
        recomputeOnTimeStatus(now: now, metersIntoLeg: candidate.metersIntoLeg)
        trainProgress = nil
        trainSnapTask?.cancel()
        snappedLocation = location
    }

    /// Runs the train-specific snap on `TrackSnapper`, an actor, and writes the result
    /// back once it lands. Pass `location: nil` for `TrackSnapper`'s dead-reckoning
    /// path. See `CommuteMode-State.md`.
    private func snapToTrack(location: Coordinates?, leg: RouteLeg, now: Date) {
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

    /// Projects the position along the current train leg when GPS is stale.
    /// Delegates to `TrackSnapper`'s `rawCoordinate: nil` path, which holds then dead-reckons.
    func deadReckonTrainLeg(now: Date) {
        guard result.legs.indices.contains(currentLegIndex) else { return }
        let leg = result.legs[currentLegIndex]
        guard leg.mode == .train else { return }
        snapToTrack(location: nil, leg: leg, now: now)
    }

    /// Returns the current leg's geometry and confirmed progress for polyline projection.
    /// `CommutePositionResolver.tick(context:now:)` uses this to project forward when GPS is stale.
    var currentLegProjectionContext: LegProjectionContext? {
        guard legGeometries.indices.contains(currentLegIndex) else { return nil }
        let geo = legGeometries[currentLegIndex]
        return LegProjectionContext(
            coords: geo.coords.map { Coordinates(lat: $0.latitude, lng: $0.longitude) },
            cumulativeMeters: geo.cumulativeMeters,
            totalMeters: geo.totalMeters,
            metersIntoLeg: metersIntoCurrentLeg
        )
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
