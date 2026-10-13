//
//  CommuteRerouteMonitor.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 9/21/26.
//

import CoreLocation
import Foundation

/// Decides when a passenger has genuinely left the current walk leg — not just drifted
/// on ordinary GPS noise. Fed one fix at a time from `ContentView`'s existing location
/// handler; only ever armed while the current leg is a walk. See `CommuteMode-State.md`.
final class CommuteRerouteMonitor {

    /// Minimum distance off the route before a fix even counts as a candidate deviation.
    /// Matches `CommuteProgressEngine.maxSnapDistanceMeters` — the same point the engine
    /// already stops trusting the snap and shows the raw fix instead of a projected one.
    static let offRouteThresholdMeters: CLLocationDistance = 75
    /// Below this speed the passenger isn't walking meaningfully — GPS jitter under a
    /// stationary phone must never count toward a deviation.
    static let minWalkingSpeedMetersPerSecond: CLLocationSpeed = 0.5
    /// How far the fix's course must diverge from the route's own forward bearing before
    /// it counts as "moving away" rather than "crossing" or "roughly parallel". Kept below
    /// 90° on purpose: Makati's street grid is diagonal, so a passenger walking a genuinely
    /// wrong parallel street can sit only a little past perpendicular to the planned leg.
    static let awayBearingDegrees: Double = 60
    /// How long the distance and bearing gates must hold together before a reroute
    /// actually fires. One bad fix must never trigger a network call on its own.
    static let sustainSeconds: TimeInterval = 8
    /// Suppresses re-triggering right after a reroute succeeds, so the just-fetched leg
    /// has a moment to register before the monitor judges it too. Armed by `armCooldown(now:)`,
    /// not by `evaluate(...)` itself — a failed attempt must not pay this delay before retrying.
    static let cooldownSeconds: TimeInterval = 20

    private var streakStartedAt: Date?
    private var cooldownUntil: Date?

    /// Evaluates one fix against the current leg's deviation signals. Returns `true`
    /// exactly once per deviation — the instant the sustained window completes — then
    /// stays `false` until the streak resets, whether by returning to the route, a
    /// non-walk leg, or an armed cooldown. Does not arm the cooldown itself — call
    /// `armCooldown(now:)` once the reroute this triggers actually succeeds.
    func evaluate(
        isWalkingLeg: Bool,
        offRouteMeters: CLLocationDistance,
        routeAheadBearing: CLLocationDirection,
        speed: CLLocationSpeed?,
        course: CLLocationDirection?,
        now: Date
    ) -> Bool {
        guard isWalkingLeg else {
            reset()
            return false
        }
        if let cooldownUntil, now < cooldownUntil { return false }

        let isDeviating = offRouteMeters > Self.offRouteThresholdMeters
            && isMovingAway(speed: speed, course: course, routeAheadBearing: routeAheadBearing)
        guard isDeviating else {
            streakStartedAt = nil
            return false
        }

        let streakStart = streakStartedAt ?? now
        streakStartedAt = streakStart
        guard now.timeIntervalSince(streakStart) >= Self.sustainSeconds else { return false }

        streakStartedAt = nil
        return true
    }

    /// Arms the cooldown after a reroute this monitor triggered actually replaced the leg.
    /// A failed attempt (offline, rate-limited) must not call this — the very next sustained
    /// deviation should retry immediately rather than wait out a cooldown for a fix that
    /// never landed.
    func armCooldown(now: Date) {
        cooldownUntil = now.addingTimeInterval(Self.cooldownSeconds)
    }

    /// True when the passenger is walking at a meaningful pace in a direction that
    /// diverges from the route, rather than toward it or roughly parallel to it (crossing
    /// a street, walking the far side of a wide road). Falls back to distance and sustain
    /// alone when course isn't available — a missing bearing must not hold a real
    /// deviation open forever waiting for one.
    private func isMovingAway(
        speed: CLLocationSpeed?, course: CLLocationDirection?, routeAheadBearing: CLLocationDirection
    ) -> Bool {
        guard let speed, speed >= Self.minWalkingSpeedMetersPerSecond,
              let course, course >= 0 else { return true }
        return angularDifference(course, routeAheadBearing) > Self.awayBearingDegrees
    }

    private func angularDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    /// Clears the streak and cooldown. Call when Commute Mode ends or a new one starts.
    func reset() {
        streakStartedAt = nil
        cooldownUntil = nil
    }
}
