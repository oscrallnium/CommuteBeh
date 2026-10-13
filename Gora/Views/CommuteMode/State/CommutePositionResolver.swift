//
//  CommutePositionResolver.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/20/26.
//

import CoreLocation
import Foundation

/// The geometry needed to project a position forward along a leg's polyline.
/// Produced by `CommuteProgressEngine.currentLegProjectionContext`.
struct LegProjectionContext {
    let coords: [Coordinates]
    /// `cumulativeMeters[i]` = metres from the first coord to `coords[i]`.
    let cumulativeMeters: [Double]
    let totalMeters: Double
    /// How far the passenger has already travelled along this leg.
    let metersIntoLeg: CLLocationDistance

    /// Linear interpolation between the two coords surrounding `meters`.
    func coordinate(atMeters meters: Double) -> Coordinates? {
        guard coords.count >= 2 else { return coords.first }
        let clamped = max(0, min(totalMeters, meters))
        for i in 0..<(cumulativeMeters.count - 1) {
            guard clamped <= cumulativeMeters[i + 1] else { continue }
            let span = cumulativeMeters[i + 1] - cumulativeMeters[i]
            let t = span > 0 ? (clamped - cumulativeMeters[i]) / span : 0
            let a = coords[i], b = coords[i + 1]
            return Coordinates(lat: a.lat + t * (b.lat - a.lat),
                               lng: a.lng + t * (b.lng - a.lng))
        }
        return coords.last
    }
}

/// Provides the best position estimate for a commuting passenger: the last GPS
/// fix while fixes arrive, a polyline-projected estimate once they stop (a
/// tunnel, a signal drop). See `CommuteMode-State.md`.
@Observable
final class CommutePositionResolver {

    /// The best available coordinate: real GPS when fresh, polyline-projected when stale.
    private(set) var resolvedCoordinate: Coordinates?
    /// True when `resolvedCoordinate` came from dead reckoning rather than GPS. Also true
    /// while merely holding the last fix (see `isProjectingForward` to tell them apart).
    private(set) var isDeadReckoned: Bool = false
    /// True only when this tick actually advanced the position along the polyline — not
    /// when it held the last fix because the passenger wasn't moving before signal loss.
    private(set) var isProjectingForward: Bool = false

    private var lastFixCoordinate: Coordinates?
    private var lastFixSpeed: CLLocationSpeed = 0
    private var lastFixAt: Date?

    /// Gap before dead reckoning begins. Long enough to skip a single dropped sample;
    /// short enough to bridge a typical tunnel entrance (5–10 s without a fix).
    static let deadReckonAfterSeconds: TimeInterval = 5
    /// Dead reckoning stops after this many seconds. Speed-drift makes the projection
    /// less useful than holding the last known position past this duration.
    static let deadReckonCapSeconds: TimeInterval = 10
    /// Below this speed the passenger is effectively stopped: do not project forward.
    static let minMovingSpeedMetersPerSecond: Double = 2.0

    /// Call on every accepted GPS fix.
    func recordFix(_ location: Coordinates, speed: CLLocationSpeed?, at now: Date) {
        lastFixCoordinate = location
        lastFixAt = now
        lastFixSpeed = max(0, speed ?? 0)
        resolvedCoordinate = location
        isDeadReckoned = false
        isProjectingForward = false
    }

    /// Call on a 1 Hz timer tick to advance the projection along the leg polyline.
    /// `context` comes from `CommuteProgressEngine.currentLegProjectionContext`.
    func tick(context: LegProjectionContext?, now: Date) {
        guard let lastFixAt, let lastFixCoordinate else { return }
        let gap = now.timeIntervalSince(lastFixAt)

        guard gap > Self.deadReckonAfterSeconds else {
            resolvedCoordinate = lastFixCoordinate
            isDeadReckoned = false
            isProjectingForward = false
            return
        }

        let elapsed = gap - Self.deadReckonAfterSeconds
        guard elapsed <= Self.deadReckonCapSeconds,
              lastFixSpeed >= Self.minMovingSpeedMetersPerSecond,
              let ctx = context else {
            resolvedCoordinate = lastFixCoordinate
            isDeadReckoned = true
            isProjectingForward = false
            return
        }

        let projectedMeters = min(ctx.totalMeters,
                                  ctx.metersIntoLeg + lastFixSpeed * elapsed)
        resolvedCoordinate = ctx.coordinate(atMeters: projectedMeters)
                             ?? lastFixCoordinate
        isDeadReckoned = true
        isProjectingForward = true
    }

    /// Resets all state when commute mode ends.
    func reset() {
        resolvedCoordinate = nil
        isDeadReckoned = false
        isProjectingForward = false
        lastFixCoordinate = nil
        lastFixSpeed = 0
        lastFixAt = nil
    }
}
