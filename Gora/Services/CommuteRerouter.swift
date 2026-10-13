//
//  CommuteRerouter.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 9/21/26.
//

import Foundation
import MapKit

/// Re-measures the current walk leg from the passenger's live position once
/// `CommuteRerouteMonitor` decides they've left it. The walking-specific twin of
/// `refineWalkLegs()` in `WalkRouteRefiner.swift`: that one re-measures every walk leg
/// before the ride starts, against the leg's original endpoints; this one re-measures
/// one leg mid-ride, from wherever the passenger actually is now. Both go through
/// `DirectionsGateway` and both share `RouteLeg.copy(...)`/`shiftingArrival(...)`.
/// See `Commute.md`.
@MainActor
extension RouteStore {

    /// Rewrites `legs[legIndex]` with a fresh walking path from `live` to the same
    /// endpoint the leg already ended at, and shifts every later leg's ETA by the
    /// difference against what was still owed on the old path. Updates `routeResult`
    /// (map polyline, card text) and `engine` (progress tracking) together, so they
    /// never disagree about which geometry is current.
    ///
    /// Returns `false` on failure — offline or rate-limited — leaving the leg as it was.
    /// The caller must not treat a `false` result as a completed reroute: it should skip
    /// arming `CommuteRerouteMonitor`'s cooldown so the next sustained deviation retries
    /// right away instead of waiting out a cooldown for a fix that never landed.
    @discardableResult
    func rerouteCurrentWalkLeg(from live: Coordinates, legIndex: Int, engine: CommuteProgressEngine) async -> Bool {
        guard !isRerouting,
              let result = routeResult,
              result.legs.indices.contains(legIndex)
        else { return false }
        let leg = result.legs[legIndex]
        guard leg.mode == .walk, let to = leg.polylineCoordinates.last else { return false }

        isRerouting = true
        defer { isRerouting = false }

        guard let path = await DirectionsGateway.shared.path(
            from: live, to: to, transport: .walking, urgency: .interactive
        ) else { return false }

        // The stretch of this leg already walked is sunk cost — only the time still
        // owed on it goes back to the schedule, not the leg's original full duration.
        let totalMeters = engine.metersIntoCurrentLeg + engine.metersRemainingOnCurrentLeg
        let remainingPlannedMinutes = totalMeters > 0
            ? leg.effectiveTravelMinutes * engine.metersRemainingOnCurrentLeg / totalMeters
            : leg.effectiveTravelMinutes
        let shiftMinutes = path.minutes - remainingPlannedMinutes

        var legs = result.legs
        legs[legIndex] = leg.copy(
            effectiveTravelMinutes: path.minutes,
            distanceKm: path.distanceKm,
            polylineCoordinates: path.coordinates,
            estimatedArrival: leg.estimatedArrival.addingTimeInterval(shiftMinutes * 60)
        )
        for i in (legIndex + 1)..<legs.count {
            legs[i] = legs[i].shiftingArrival(byMinutes: shiftMinutes)
        }

        let newResult = result.replacingLegs(legs)
        routeResult = newResult
        engine.applyReroute(newResult)
        return true
    }
}
