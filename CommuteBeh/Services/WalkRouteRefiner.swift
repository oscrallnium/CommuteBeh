//
//  WalkRouteRefiner.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/31/26.
//

import Foundation
import MapKit
import OSLog

/// Walk refinement is invisible when it works and leaves a bare gap when it doesn't. These
/// lines say which happened, per leg. Filter with:
/// `log stream --predicate 'category == "Directions"'`
let directionsLog = Logger(subsystem: "com.banaueinc.commutebeh.CommuteBeh", category: "Directions")
private let walkLog = directionsLog

// MARK: - Walk Leg Refinement
//
// Every walk in a route arrives as a straight line. Access walks are measured by the engine
// as straight-line distance × a 1.3 detour factor; interchange walks come straight from the
// JSON as a two-point chord between the two stations. Both are fine as *data* — cheap, no
// network, good enough for A* to choose with — but neither is a path anyone can follow. A
// stop 400 m away across a river, an expressway with no crossing, or the far side of a
// walled campus is a 400 m estimate and a 1.8 km reality.
//
// So every walk leg in the surviving routes is re-measured against real MKDirections
// pedestrian geometry once the results are already on screen. Legs are rewritten with the
// true duration, distance and street-following polyline.
//
// Access walks additionally get a plausibility check: one whose real walking distance blows
// past `AccessPolicy.hardCeilingKm` takes its whole route with it, because that route was
// only ever offered on the strength of a straight line. Interchange walks are never grounds
// for dropping a route — they are the network's own recorded transfers, not something
// inferred from a pin the user dropped.
//
// This runs *after* `calculateRoute` publishes, never before: the user sees results at
// engine speed and they sharpen a moment later.

/// One MKDirections walking measurement.
private struct WalkMeasurement {
    let minutes: Double
    let distanceKm: Double
    let coordinates: [Coordinates]
}

@MainActor
extension CommuteViewModel {

    /// Re-measures every walk leg in `routeOptions` against real walking directions.
    ///
    /// Bails out without touching state if the options list changed while measuring (the
    /// user picked a route, edited an endpoint, or searched again) — a late write would
    /// otherwise re-open a panel the user had just dismissed.
    func refineWalkLegs() async {
        let snapshot = routeOptions
        guard snapshot.contains(where: { $0.result.legs.contains { $0.mode == .walk } }) else { return }
        let snapshotIDs = snapshot.map(\.id)

        // Which option is on the map right now. `previewRoute` may have moved it off the
        // first one, and `selectRoute` empties `routeOptions` while leaving that option's
        // result as `routeResult` — so this index is the only link back once the panel is
        // gone. Leg ids are stable UUIDs, which is what makes the match reliable.
        let shownIndex = snapshot.firstIndex {
            $0.result.legs.first?.id == routeResult?.legs.first?.id
        }

        // Keyed by rounded endpoint pair: the three strategies mostly share the same walks
        // (and an interchange walk repeats verbatim across them), so this collapses to a
        // handful of network round-trips per search rather than one per leg per option.
        var cache: [String: WalkMeasurement?] = [:]
        // Positional, so a dropped option (nil) doesn't shift the index the shown route
        // is found by.
        var refined: [RouteOption?] = []

        for option in snapshot {
            refined.append(await refine(option, cache: &cache))
            if Task.isCancelled { return }
        }

        let survivors = refined.compactMap { $0 }
        let shownRefined = shownIndex.flatMap { refined[$0] }

        // The user committed to a route while we were measuring: the options list is gone,
        // but the map is still showing that route — and the map is exactly where a
        // straight-line walk is visible. Update it in place.
        //
        // Note the asymmetry with the branch below: a selected route is never *removed*
        // here, even if its access walk turned out to be too long. Dropping a candidate
        // from a list of three is a helpful filter; yanking the route the user is actively
        // looking at is not. They keep it, with honest geometry where we have it.
        guard routeOptions.map(\.id) == snapshotIDs else {
            if routeOptions.isEmpty, let shownRefined {
                routeResult = shownRefined.result
            }
            return
        }

        if survivors.isEmpty {
            // Every option died on its access walk — say so, rather than leaving stale
            // options on screen that we know to be unwalkable.
            routeOptions = []
            routeResult = nil
            errorMessage = "No route found — the walk to the nearest stop is too long on foot."
            return
        }

        routeOptions = survivors
        routeResult = shownRefined?.result ?? survivors.first?.result
    }

    // MARK: Per-option rebuild

    /// Returns the option with its walk legs re-measured, or `nil` when an access walk's
    /// real walking distance exceeds the hard ceiling and the option should be discarded.
    private func refine(
        _ option: RouteOption,
        cache: inout [String: WalkMeasurement?]
    ) async -> RouteOption? {
        var legs: [RouteLeg] = []
        // Running clock shift: a longer (or shorter) walk moves every later leg's ETA.
        var shiftMinutes: Double = 0

        for leg in option.result.legs {
            guard leg.mode == .walk else {
                legs.append(leg.shiftingArrival(byMinutes: shiftMinutes))
                continue
            }

            guard let measurement = await measureWalk(for: leg, cache: &cache) else {
                // MapKit couldn't route this walk even after retries (offline, throttled, no
                // pedestrian path known). The leg keeps its time and distance estimate and
                // stays in the route — dropping trips on a network failure would hide
                // perfectly good ones — but it draws *nothing*. A straight chord across
                // whatever is in the way is worse than an honest gap, and the JSON's
                // two-point interchange lines are stripped here for the same reason.
                legs.append(leg.shiftingArrival(byMinutes: shiftMinutes).withoutStraightLine())
                continue
            }

            // Plausibility check applies to access walks only: an interchange walk is the
            // network's own recorded transfer, and a MapKit detour around it is not a reason
            // to hide the route it belongs to.
            if leg.isAccessWalk, measurement.distanceKm > AccessPolicy.hardCeilingKm {
                return nil
            }

            shiftMinutes += measurement.minutes - leg.effectiveTravelMinutes
            legs.append(leg.replacingWalk(
                minutes: measurement.minutes,
                distanceKm: measurement.distanceKm,
                polyline: measurement.coordinates,
                arrivalShiftMinutes: shiftMinutes
            ))
        }

        return RouteOption(result: option.result.replacingLegs(legs), label: option.label)
    }

    // MARK: Measurement

    private func measureWalk(
        for leg: RouteLeg,
        cache: inout [String: WalkMeasurement?]
    ) async -> WalkMeasurement? {
        // Take MapKit's transport type from the edge's own hint rather than assuming a walk
        // leg wants pedestrian geometry. Every walk edge in the data says "walking"; if one
        // ever says otherwise, draw nothing rather than a car route over a leg the user is
        // told to walk.
        let hint = leg.rawSteps.first?.edge.mkDirectionsTransportType
        guard DirectionsTransport.snapType(for: hint) == .walking else {
            walkLog.error("""
                \(leg.instruction, privacy: .public): edge hint is \
                \(hint ?? "nil", privacy: .public), not walking — no geometry drawn
                """)
            return nil
        }

        let from = leg.fromStation.coordinates
        let to   = leg.toStation.coordinates
        let key = String(format: "%.5f,%.5f>%.5f,%.5f", from.lat, from.lng, to.lat, to.lng)
        if let cached = cache[key] { return cached }

        let measurement = await Self.walkingDirections(from: from, to: to)
        cache[key] = measurement

        if let measurement {
            // .notice, not .info: `log stream` hides info-level by default, and the success
            // line is exactly what you need next to the failures to tell them apart.
            walkLog.notice("""
                \(leg.instruction, privacy: .public): walked \
                \(Int(measurement.distanceKm * 1000), privacy: .public) m in \
                \(Int(measurement.minutes), privacy: .public) min, \
                \(measurement.coordinates.count, privacy: .public) pts \
                (straight line was \(Int(leg.distanceKm * 1000), privacy: .public) m)
                """)
        } else {
            walkLog.error("""
                \(leg.instruction, privacy: .public): MKDirections walking failed or timed \
                out after retries — leg draws nothing rather than a straight line
                """)
        }
        return measurement
    }

    /// Real pedestrian route between two coordinates, or `nil` once every attempt has failed.
    ///
    /// Goes through `DirectionsGateway`, which paces and caches every MKDirections call in
    /// the app — the failure this refiner kept hitting was Apple's rate limiter answering
    /// "Directions Not Available", not a missing footpath.
    ///
    /// Still retried on top of that: there is no straight-line fallback anywhere in this
    /// file, so a transient failure costs the user a visible gap. Backoff is generous
    /// because the limiter needs wall-clock time to clear, and this runs off the critical
    /// path where nobody is blocked on it.
    private static func walkingDirections(
        from: Coordinates,
        to: Coordinates
    ) async -> WalkMeasurement? {
        let backoff: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
        for attempt in 0...backoff.count {
            if let path = await DirectionsGateway.shared.path(
                from: from, to: to, transport: .walking, urgency: .interactive
            ) {
                return WalkMeasurement(minutes: path.minutes,
                                       distanceKm: path.distanceKm,
                                       coordinates: path.coordinates)
            }
            guard attempt < backoff.count, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: backoff[attempt])
        }
        return nil
    }
}

// MARK: - Immutable leg/result rewrites

private extension RouteLeg {

    /// Same leg, ETA moved by the drift accumulated from earlier re-measured walks.
    func shiftingArrival(byMinutes minutes: Double) -> RouteLeg {
        guard minutes != 0 else { return self }
        return copy(estimatedArrival: estimatedArrival.addingTimeInterval(minutes * 60))
    }

    /// Drops a two-point polyline — by definition a chord between the leg's endpoints, not a
    /// path. Legs with real geometry (three points or more, i.e. something a router or a
    /// recorder produced) are left alone.
    func withoutStraightLine() -> RouteLeg {
        guard polylineCoordinates.count <= 2 else { return self }
        return copy(polylineCoordinates: [])
    }

    /// Access-walk leg rewritten with real walking geometry.
    ///
    /// `rawSteps` is deliberately left as the engine produced it: it carries the synthetic
    /// access edge that A* actually traversed, and downstream consumers (per-segment ETA
    /// calls, AR navigation) read it as the record of the search, not of this refinement.
    func replacingWalk(
        minutes: Double,
        distanceKm: Double,
        polyline: [Coordinates],
        arrivalShiftMinutes: Double
    ) -> RouteLeg {
        copy(
            effectiveTravelMinutes: minutes,
            distanceKm: distanceKm,
            polylineCoordinates: pinningStationEnds(of: polyline),
            estimatedArrival: estimatedArrival.addingTimeInterval(arrivalShiftMinutes * 60)
        )
    }

    /// Snaps the polyline's ends onto this leg's **stations** — and only its stations.
    ///
    /// A stop sits on the road its vehicles use, so MKDirections lands within a metre of it
    /// and any residual drift is noise worth removing: the map draws stop pins from station
    /// coordinates, and a metre of daylight between pin and line reads as a defect.
    ///
    /// A *pinned location* is the opposite case. MKDirections has already snapped it to the
    /// road in front of the address — 2 to 19 m away in the routes measured — and that
    /// snapped point is where the walk genuinely begins. Overwriting it with the raw pin
    /// deleted the first vertex and drew the second one instead, turning the short hop onto
    /// the road into a 70–136 m diagonal straight across to the next intersection. Leaving
    /// it alone costs a few metres of honest gap between the pin and the path — MapKit has
    /// no data for the walk from inside a mall to its gate — and buys a line that actually
    /// follows the road.
    func pinningStationEnds(of polyline: [Coordinates]) -> [Coordinates] {
        guard polyline.count >= 2 else { return polylineCoordinates }
        var pinned = polyline
        if !fromStation.isPinnedLocation { pinned[0] = fromStation.coordinates }
        if !toStation.isPinnedLocation { pinned[pinned.count - 1] = toStation.coordinates }
        return pinned
    }

    func copy(
        effectiveTravelMinutes: Double? = nil,
        distanceKm: Double? = nil,
        polylineCoordinates: [Coordinates]? = nil,
        estimatedArrival: Date? = nil
    ) -> RouteLeg {
        RouteLeg(
            fromStation: fromStation,
            toStation: toStation,
            mode: mode,
            line: line,
            direction: direction,
            stops: stops,
            effectiveTravelMinutes: effectiveTravelMinutes ?? self.effectiveTravelMinutes,
            fare: fare,
            distanceKm: distanceKm ?? self.distanceKm,
            polylineCoordinates: polylineCoordinates ?? self.polylineCoordinates,
            estimatedArrival: estimatedArrival ?? self.estimatedArrival,
            instruction: instruction,
            rawSteps: rawSteps
        )
    }
}

private extension RouteResult {
    /// Totals are re-derived from the rewritten legs; transfers and modes are unchanged
    /// because refinement only ever touches walk legs, which count for neither.
    func replacingLegs(_ legs: [RouteLeg]) -> RouteResult {
        RouteResult(
            legs: legs,
            totalTimeMinutes: legs.reduce(0) { $0 + $1.effectiveTravelMinutes },
            totalFare: legs.reduce(0) { $0 + $1.fare },
            totalDistanceKm: legs.reduce(0) { $0 + $1.distanceKm },
            transfers: transfers,
            modes: modes
        )
    }
}
