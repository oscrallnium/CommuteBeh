//
//  RoadTrafficRefiner.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import Foundation
import os

/// Traffic factors for road legs. A factor is the driving time now divided by the driving
/// time at the next 3:00 a.m., both from MapKit through `DirectionsGateway`.
enum RoadTraffic {
    static let factorRange = 1.0...4.0

    /// True for a bus, jeepney, UV Express, or tricycle leg that is not a walk between platforms.
    static func isRoadLeg(_ leg: RouteLeg) -> Bool {
        guard leg.line != "INTERCHANGE", leg.line != "ACCESS_WALK" else { return false }
        return [TransportMode.bus, .jeepney, .uvExpress, .tricycle].contains(leg.mode)
    }

    /// Sum of the free-flow minutes of every edge in the leg.
    static func freeFlowMinutes(of leg: RouteLeg) -> Double {
        leg.rawSteps.reduce(0) { $0 + $1.edge.travelTimeMinutes }
    }

    /// Traffic factor between two points, or `nil` when either ETA is missing or zero.
    /// `freeFlowOnDisk` is false when `from` is a live position that never repeats.
    static func factor(
        for leg: RouteLeg,
        from: Coordinates,
        to: Coordinates,
        freeFlowOnDisk: Bool,
        urgency: DirectionsGateway.Urgency
    ) async -> Double? {
        let now = Date()
        let night = nextFreeFlowDeparture(after: now)
        guard let nowSeconds = await DirectionsGateway.shared.travelSeconds(
                  from: from, to: to, departure: now, cacheOnDisk: false, urgency: urgency),
              let freeSeconds = await DirectionsGateway.shared.travelSeconds(
                  from: from, to: to, departure: night, cacheOnDisk: freeFlowOnDisk, urgency: urgency),
              nowSeconds > 0, freeSeconds > 0 else {
            directionsLog.error("traffic \(leg.line, privacy: .public): ETA missing")
            return nil
        }
        let factor = min(max(nowSeconds / freeSeconds, factorRange.lowerBound), factorRange.upperBound)
        directionsLog.notice("""
            traffic \(leg.line, privacy: .public) \(String(describing: leg.mode), privacy: .public): \
            now \(Int(nowSeconds), privacy: .public) s, free-flow \(Int(freeSeconds), privacy: .public) s, \
            factor \(factor, format: .fixed(precision: 2), privacy: .public)
            """)
        return factor
    }

    /// The next 3:00 a.m. local time, when roads carry the least traffic.
    private static func nextFreeFlowDeparture(after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: 3),
                                  matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    /// The route with the current and later road legs retimed from traffic, or `nil` when no
    /// leg changed. The elapsed part of the current leg keeps its time.
    static func retimed(
        _ result: RouteResult,
        legIndex: Int,
        live: Coordinates?,
        metersInto: Double,
        metersRemaining: Double
    ) async -> RouteResult? {
        guard result.legs.indices.contains(legIndex) else { return nil }
        var legs = result.legs
        var shift: Double = 0
        var changed = false

        for index in legIndex..<legs.count {
            let leg = legs[index]
            let free = freeFlowMinutes(of: leg)
            let isCurrent = index == legIndex
            let origin = isCurrent ? live : leg.fromStation.coordinates
            guard isRoadLeg(leg), free > 0, let origin,
                  let factor = await factor(for: leg, from: origin, to: leg.toStation.coordinates,
                                            freeFlowOnDisk: !isCurrent, urgency: .background)
            else {
                legs[index] = leg.shiftingArrival(byMinutes: shift)
                continue
            }

            var minutes = free * factor
            if isCurrent {
                let total = metersInto + metersRemaining
                let share = total > 0 ? metersRemaining / total : 1
                minutes = leg.effectiveTravelMinutes * (1 - share) + free * share * factor
            }
            shift += minutes - leg.effectiveTravelMinutes
            legs[index] = leg.copy(
                effectiveTravelMinutes: minutes,
                estimatedArrival: leg.estimatedArrival.addingTimeInterval(shift * 60)
            )
            changed = true
        }
        return changed ? result.replacingLegs(legs) : nil
    }
}

@MainActor
extension RouteStore {

    /// Retimes the road legs of every option in `routeOptions`, then re-sorts the options.
    /// Bails without writing when the options list changed during the requests.
    func applyTrafficToRoadLegs() async {
        let snapshot = routeOptions
        guard !snapshot.isEmpty else { return await retimeSelectedRoute() }
        guard snapshot.contains(where: { $0.result.legs.contains(where: RoadTraffic.isRoadLeg) }) else { return }
        let snapshotIDs = snapshot.map(\.id)
        let shownIndex = snapshot.firstIndex {
            $0.result.legs.first?.id == routeResult?.legs.first?.id
        }

        var cache: [String: Double?] = [:]
        var rebuilt: [RouteOption] = []
        for option in snapshot {
            let result = await retimed(option.result, cache: &cache)
            rebuilt.append(RouteOption(result: result, label: option.label, id: option.id))
            if Task.isCancelled { return }
        }
        let shown = shownIndex.map { rebuilt[$0] }

        guard routeOptions.map(\.id) == snapshotIDs else {
            if routeOptions.isEmpty, let shown { routeResult = shown.result }
            return
        }
        routeOptions = rebuilt.sortedByDuration()
        routeResult = shown?.result ?? routeOptions.first?.result
    }

    /// Retimes the route on the map after `selectRoute` emptied `routeOptions`.
    private func retimeSelectedRoute() async {
        guard let current = routeResult else { return }
        var cache: [String: Double?] = [:]
        let result = await retimed(current, cache: &cache)
        guard !Task.isCancelled, routeResult?.legs.first?.id == current.legs.first?.id else { return }
        routeResult = result
    }

    private func retimed(_ result: RouteResult, cache: inout [String: Double?]) async -> RouteResult {
        var legs: [RouteLeg] = []
        var shift: Double = 0

        for leg in result.legs {
            let free = RoadTraffic.freeFlowMinutes(of: leg)
            guard RoadTraffic.isRoadLeg(leg), free > 0,
                  let factor = await trafficFactor(for: leg, cache: &cache) else {
                legs.append(leg.shiftingArrival(byMinutes: shift))
                continue
            }
            let minutes = free * factor
            shift += minutes - leg.effectiveTravelMinutes
            legs.append(leg.copy(
                effectiveTravelMinutes: minutes,
                estimatedArrival: leg.estimatedArrival.addingTimeInterval(shift * 60)
            ))
        }
        return result.replacingLegs(legs)
    }

    /// One request pair per endpoint pair, shared across every option.
    private func trafficFactor(for leg: RouteLeg, cache: inout [String: Double?]) async -> Double? {
        let from = leg.fromStation.coordinates, to = leg.toStation.coordinates
        let key = String(format: "%.5f,%.5f>%.5f,%.5f", from.lat, from.lng, to.lat, to.lng)
        if let cached = cache[key] { return cached }
        let factor = await RoadTraffic.factor(for: leg, from: from, to: to,
                                              freeFlowOnDisk: true, urgency: .interactive)
        cache[key] = factor
        return factor
    }
}
