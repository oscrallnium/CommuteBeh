//
//  LineAlternatives.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/11/26.
//

import CoreLocation

/// Another line that a commuter can ride between the same two stops as a chosen ride leg.
nonisolated struct LineAlternative: Codable, Hashable, Sendable {
    let line: String
    let boardStation: Station
    let alightStation: Station
    let rideMinutes: Double
    let fare: Double
    let acceptedPayments: [String]
    let isAirConditioned: Bool
    let direction: String?

    /// The mode of the alternative line, read from its boarding station.
    var mode: TransportMode? { TransportMode(rawValue: boardStation.type) }
}

/// The rules that decide which stations and rides count as an alternative to a ride leg.
nonisolated enum LineAlternativePolicy {
    /// Longest distance between two stations that count as one physical stop.
    static let sameStopKm: Double = 0.15
    /// An alternative may exceed the chosen ride by the larger of this and `slackFraction`.
    static let slackMinutes: Double = 5
    static let slackFraction: Double = 0.25

    static func maxRideMinutes(chosen: Double) -> Double {
        chosen + max(slackMinutes, slackFraction * chosen)
    }

    static func isSameStop(_ a: Coordinates, _ b: Coordinates) -> Bool {
        let from = CLLocation(latitude: a.lat, longitude: a.lng)
        let to = CLLocation(latitude: b.lat, longitude: b.lng)
        return from.distance(from: to) / 1000 <= sameStopKm
    }

    /// A station of another line, of any mode, within the stop radius, where boarding is allowed.
    static func isBoardingCandidate(_ station: Station, near stop: Station, excludingLine line: String) -> Bool {
        station.line != line && !station.isAlightOnly
            && isSameStop(station.coordinates, stop.coordinates)
    }

    /// A station of `line` within the stop radius of `stop`.
    static func isAlightTarget(_ station: Station, near stop: Station, onLine line: String) -> Bool {
        station.line == line && !station.isBoardOnly && isSameStop(station.coordinates, stop.coordinates)
    }
}

extension TransitGraphEngine {
    private struct SearchContext {
        let payments: Set<String>
        let allowedModes: Set<TransportMode>
        let departure: Date
        let departureMinutes: Int
    }

    /// Returns `result` with the alternative lines of each ride leg filled in. Totals and legs
    /// otherwise stay as they are.
    func withAlternatives(_ result: RouteResult, request: RouteRequest) -> RouteResult {
        let context = SearchContext(
            payments: request.preferredPayments,
            allowedModes: request.allowedModes,
            departure: request.departureTime,
            departureMinutes: Self.minutesSinceMidnight(request.departureTime)
        )
        var changed = false
        let legs = result.legs.map { leg -> RouteLeg in
            let alternatives = alternativeLines(for: leg, context: context)
            guard !alternatives.isEmpty else { return leg }
            changed = true
            return RouteLeg(
                id: leg.id,
                fromStation: leg.fromStation,
                toStation: leg.toStation,
                mode: leg.mode,
                line: leg.line,
                direction: leg.direction,
                stops: leg.stops,
                effectiveTravelMinutes: leg.effectiveTravelMinutes,
                fare: leg.fare,
                distanceKm: leg.distanceKm,
                polylineCoordinates: leg.polylineCoordinates,
                estimatedArrival: leg.estimatedArrival,
                instruction: leg.instruction,
                rawSteps: leg.rawSteps,
                alternativeLines: alternatives,
                scheduledDeparture: leg.scheduledDeparture,
                waitMinutes: leg.waitMinutes
            )
        }
        guard changed else { return result }
        return RouteResult(
            legs: legs,
            totalTimeMinutes: result.totalTimeMinutes,
            totalFare: result.totalFare,
            totalDistanceKm: result.totalDistanceKm,
            transfers: result.transfers,
            modes: result.modes
        )
    }

    private func alternativeLines(for leg: RouteLeg, context: SearchContext) -> [LineAlternative] {
        guard let first = leg.rawSteps.first, !isWalkLikeEdge(first.edge), !first.edge.isZoneRide else { return [] }
        let modeID = first.edge.mode
        let peak = peakTable.multiplier(forMode: modeID, atMinutes: context.departureMinutes)
        let chosenMinutes = leg.rawSteps.reduce(0) { $0 + $1.edge.travelTimeMinutes * peak }
        let limit = LineAlternativePolicy.maxRideMinutes(chosen: chosenMinutes)
        let boardDate = first.estimatedArrival.addingTimeInterval(-first.effectiveTravelMinutes * 60)
        let boardMinutes = Self.minutesSinceMidnight(boardDate)

        var best: [String: LineAlternative] = [:]
        for index in stationGrid.indices(near: leg.fromStation.coordinates, radiusKm: LineAlternativePolicy.sameStopKm) {
            let start = stationList[index]
            guard LineAlternativePolicy.isBoardingCandidate(start, near: leg.fromStation,
                                                            excludingLine: leg.line) else { continue }
            let candidatePeak = peakTable.multiplier(forMode: start.type, atMinutes: context.departureMinutes)
            let targets = alightTargets(near: leg.toStation, line: start.line)
            guard !targets.isEmpty,
                  let steps = fastestRide(from: start, targets: targets, modeID: start.type,
                                          peak: candidatePeak, limit: limit, boardMinutes: boardMinutes, context: context),
                  let alternative = makeAlternative(steps) else { continue }
            if let known = best[start.line], known.rideMinutes <= alternative.rideMinutes { continue }
            best[start.line] = alternative
        }
        return best.values.sorted { ($0.rideMinutes, $0.fare) < ($1.rideMinutes, $1.fare) }
    }

    private func alightTargets(near stop: Station, line: String) -> Set<StationID> {
        let indices = stationGrid.indices(near: stop.coordinates, radiusKm: LineAlternativePolicy.sameStopKm)
        return Set(indices.map { stationList[$0] }
            .filter { LineAlternativePolicy.isAlightTarget($0, near: stop, onLine: line) }
            .map(\.id))
    }

    /// Fastest ride along the edges of the start line and mode only, bounded by `limit` minutes.
    /// The payment, mode, and operating-hours filters match the A* filters.
    private func fastestRide(
        from start: Station, targets: Set<StationID>, modeID: String, peak: Double,
        limit: Double, boardMinutes: Int, context: SearchContext
    ) -> [RawStep]? {
        var best: [StationID: Double] = [start.id: 0]
        var via: [StationID: TransitEdge] = [:]
        var settled: Set<StationID> = []
        var frontier: [StationID] = [start.id]
        while let next = frontier.indices.min(by: { best[frontier[$0]] ?? 0 < best[frontier[$1]] ?? 0 }) {
            let id = frontier.remove(at: next)
            guard settled.insert(id).inserted else { continue }
            let time = best[id] ?? 0
            if id != start.id, targets.contains(id) {
                return rawSteps(to: id, via: via, peak: peak, departure: context.departure)
            }
            for item in adjacency[id] ?? [] {
                let edge = item.edge
                guard edge.line == start.line, edge.mode == modeID, !item.isWalkLike, !edge.isZoneRide,
                      !settled.contains(edge.to) else { continue }
                if !context.payments.isEmpty, item.payments.isDisjoint(with: context.payments) { continue }
                if !context.allowedModes.isEmpty, !(item.mode.map(context.allowedModes.contains) ?? false) { continue }
                let total = time + edge.travelTimeMinutes * peak
                guard total <= limit, let neighbor = stationMap[edge.to] else { continue }
                if enforceOperatingHours, let window = openWindows[neighbor.id],
                   !window.contains(arrivalMinutes: boardMinutes + Int(total)) { continue }
                guard total < (best[neighbor.id] ?? .infinity) else { continue }
                best[neighbor.id] = total
                via[neighbor.id] = edge
                frontier.append(neighbor.id)
            }
        }
        return nil
    }

    private func rawSteps(to target: StationID, via: [StationID: TransitEdge], peak: Double,
                          departure: Date) -> [RawStep] {
        var steps: [RawStep] = []
        var node = target
        while let edge = via[node], let from = stationMap[edge.from], let to = stationMap[node] {
            steps.append(RawStep(fromStation: from, toStation: to, edge: edge,
                                 effectiveTravelMinutes: edge.travelTimeMinutes * peak,
                                 estimatedArrival: departure))
            node = edge.from
        }
        return steps.reversed()
    }

    private func makeAlternative(_ steps: [RawStep]) -> LineAlternative? {
        guard let first = steps.first, let last = steps.last else { return nil }
        return LineAlternative(
            line: first.edge.line,
            boardStation: first.fromStation,
            alightStation: last.toStation,
            rideMinutes: steps.reduce(0) { $0 + $1.effectiveTravelMinutes },
            fare: computeLegFare(steps),
            acceptedPayments: first.edge.acceptedPayments,
            isAirConditioned: first.edge.isAirConditioned,
            direction: first.edge.direction
        )
    }

    private static func minutesSinceMidnight(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
