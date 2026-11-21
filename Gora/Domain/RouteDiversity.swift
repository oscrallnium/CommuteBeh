//
//  RouteDiversity.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/15/26.
//

import Foundation

/// Ride minutes per line of one route, the lines of its zone rides, and its trunk line.
/// The trunk is the non-zone line with the most ride minutes. A route with only zone rides uses the zone line.
nonisolated struct RideProfile {
    let minutes: [String: Double]
    let zoneLines: Set<String>
    let trunk: String?

    /// Ride minutes per line without the zone ride lines.
    var minutesWithoutZone: [String: Double] { minutes.filter { !zoneLines.contains($0.key) } }
}

/// Limits that decide which extra routes the search offers. See Domain.md.
nonisolated enum RouteDiversityPolicy {
    /// Search cost multiplier for a ride edge on a penalized line.
    static let linePenaltyFactor = 4.0
    static let maxExtraSearches = 4
    static let maxOptions = 3
    /// An extra route is acceptable when time <= max(best * slowdownFactor, best + slowdownMinutes).
    static let slowdownFactor = 1.6
    static let slowdownMinutes = 20.0
    /// Two routes are too similar when their overlap is above this share.
    static let maxOverlap = 0.6

    /// One key per route: the ordered line and station pairs of its legs.
    static func routeKey(_ result: RouteResult) -> String {
        result.legs.map { "\($0.line):\($0.fromStation.id):\($0.toStation.id)" }.joined(separator: "|")
    }

    /// Builds the profile of a route. `isRide` and `isZoneRide` classify each leg.
    static func rideProfile(
        _ result: RouteResult, isRide: (RouteLeg) -> Bool, isZoneRide: (RouteLeg) -> Bool
    ) -> RideProfile {
        var minutes: [String: Double] = [:]
        var order: [String] = []
        var zoneLines: Set<String> = []
        for leg in result.legs where isRide(leg) {
            if minutes[leg.line] == nil { order.append(leg.line) }
            minutes[leg.line, default: 0] += leg.effectiveTravelMinutes
            if isZoneRide(leg) { zoneLines.insert(leg.line) }
        }
        let others = order.filter { !zoneLines.contains($0) }
        let trunk = (others.isEmpty ? order : others).reduce(nil as String?) { best, line in
            guard let best else { return line }
            return minutes[line, default: 0] > minutes[best, default: 0] ? line : best
        }
        return RideProfile(minutes: minutes, zoneLines: zoneLines, trunk: trunk)
    }

    /// Two routes are too similar when one rides the trunk of the other, or their overlap without zone rides is above `maxOverlap`.
    static func isTooSimilar(_ a: RideProfile, _ b: RideProfile) -> Bool {
        if let trunk = a.trunk, b.minutes[trunk] != nil { return true }
        if let trunk = b.trunk, a.minutes[trunk] != nil { return true }
        return overlap(a.minutesWithoutZone, b.minutesWithoutZone) > maxOverlap
    }

    /// Shared ride minutes divided by the smaller total of ride minutes. Zero when either has no ride.
    static func overlap(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let smaller = min(a.values.reduce(0, +), b.values.reduce(0, +))
        guard smaller > 0 else { return 0 }
        let shared = a.reduce(0.0) { $0 + min($1.value, b[$1.key] ?? 0) }
        return shared / smaller
    }

    static func isAcceptableTime(_ time: Double, best: Double) -> Bool {
        time <= max(best * slowdownFactor, best + slowdownMinutes)
    }
}

extension RouteRequest {
    /// The same trip with another cost strategy and a set of penalized lines.
    func replacing(costStrategy: CostStrategy, penalizedLines: Set<String>) -> RouteRequest {
        RouteRequest(
            from: originID, to: destinationID,
            originCoordinate: originCoordinate,
            destinationCoordinate: destinationCoordinate,
            preferredPayments: preferredPayments,
            allowedModes: allowedModes,
            departureTime: departureTime,
            costStrategy: costStrategy,
            penalizedLines: penalizedLines
        )
    }
}

extension TransitGraphEngine {
    /// Drops base routes that repeat a faster base route, then searches with the lines found so far
    /// penalized, to add up to `maxOptions` distinct routes. See Domain.md.
    func diverseRoutes(base: [RouteResult], request: RouteRequest) -> [RouteResult] {
        let ordered = base.sorted { $0.totalTimeMinutes < $1.totalTimeMinutes }
        guard let best = ordered.first?.totalTimeMinutes else { return [] }

        var accepted: [RouteResult] = []
        var acceptedProfiles: [RideProfile] = []
        var seenKeys: Set<String> = []
        var penalized: Set<String> = []

        func conflict(_ profile: RideProfile) -> RideProfile? {
            acceptedProfiles.first { RouteDiversityPolicy.isTooSimilar(profile, $0) }
        }
        func noteLines(_ profile: RideProfile) {
            penalized.formUnion(Set(profile.minutes.keys).subtracting(profile.zoneLines))
        }

        for result in ordered {
            let profile = rideProfile(result)
            noteLines(profile)
            guard seenKeys.insert(RouteDiversityPolicy.routeKey(result)).inserted else {
                logCandidate("base", result, profile, "repeat")
                continue
            }
            if !accepted.isEmpty, let other = conflict(profile) {
                logCandidate("base", result, profile, "too similar to \(other.trunk ?? "-")")
                continue
            }
            logCandidate("base", result, profile, "accepted")
            accepted.append(result)
            acceptedProfiles.append(profile)
        }

        var previousPenalized: Set<String> = []
        for index in 1...RouteDiversityPolicy.maxExtraSearches {
            guard accepted.count < RouteDiversityPolicy.maxOptions,
                  !penalized.isEmpty, penalized != previousPenalized else { break }
            previousPenalized = penalized
            let next = request.replacing(costStrategy: .balanced, penalizedLines: penalized)
            guard case .success(let result) = findRoute(next), !result.isEmpty else { break }

            let profile = rideProfile(result)
            noteLines(profile)
            let label = "extra\(index)"
            guard seenKeys.insert(RouteDiversityPolicy.routeKey(result)).inserted else {
                logCandidate(label, result, profile, "repeat")
                continue
            }
            guard RouteDiversityPolicy.isAcceptableTime(result.totalTimeMinutes, best: best) else {
                logCandidate(label, result, profile, "too slow")
                continue
            }
            if let other = conflict(profile) {
                logCandidate(label, result, profile, "too similar to \(other.trunk ?? "-")")
                continue
            }
            logCandidate(label, result, profile, "accepted")
            accepted.append(result)
            acceptedProfiles.append(profile)
        }
        return accepted
    }

    private func rideProfile(_ result: RouteResult) -> RideProfile {
        RouteDiversityPolicy.rideProfile(
            result,
            isRide: { leg in leg.rawSteps.first.map { !isWalkLikeEdge($0.edge) } ?? false },
            isZoneRide: { leg in leg.rawSteps.first?.edge.isZoneRide ?? false })
    }

    private func logCandidate(_ source: String, _ result: RouteResult, _ profile: RideProfile, _ decision: String) {
        #if DEBUG
        let legs = result.legs.map(\.line).joined(separator: ">")
        print("[RouteDiversity] \(source) legs=\(legs) time=\(Int(result.totalTimeMinutes)) trunk=\(profile.trunk ?? "-") \(decision)")
        #endif
    }
}
