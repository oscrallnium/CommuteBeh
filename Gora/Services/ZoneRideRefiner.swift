//
//  ZoneRideRefiner.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/5/26.
//

import Foundation
import MapKit
import os

extension RouteLeg {
    /// True for a tricycle zone ride. The engine gives these legs an empty polyline.
    fileprivate var isZoneRide: Bool { rawSteps.first?.edge.isZoneRide == true }
}

@MainActor
extension RouteStore {

    /// Draws each zone ride leg of every option along an Apple Maps driving path.
    /// Bails without writing when the options list changed during the requests.
    func refineZoneRideLegs() async {
        let snapshot = routeOptions
        guard !snapshot.isEmpty else { return await refineSelectedZoneRides() }
        guard snapshot.contains(where: { $0.result.legs.contains(where: \.isZoneRide) }) else { return }
        let snapshotIDs = snapshot.map(\.id)
        let shownIndex = snapshot.firstIndex {
            $0.result.legs.first?.id == routeResult?.legs.first?.id
        }

        var cache: [String: [Coordinates]?] = [:]
        var rebuilt: [RouteOption] = []
        for option in snapshot {
            let result = await drawingZoneRides(option.result, cache: &cache)
            rebuilt.append(option.replacing(result: result))
            if Task.isCancelled { return }
        }
        let shown = shownIndex.map { rebuilt[$0] }

        guard routeOptions.map(\.id) == snapshotIDs else {
            if routeOptions.isEmpty, let shown { routeResult = shown.result }
            return
        }
        routeOptions = rebuilt
        routeResult = shown?.result ?? rebuilt.first?.result
    }

    /// Draws the zone rides of the route on the map after `selectRoute` emptied `routeOptions`.
    private func refineSelectedZoneRides() async {
        guard let current = routeResult, current.legs.contains(where: \.isZoneRide) else { return }
        var cache: [String: [Coordinates]?] = [:]
        let result = await drawingZoneRides(current, cache: &cache)
        guard !Task.isCancelled, routeResult?.legs.first?.id == current.legs.first?.id else { return }
        routeResult = result
    }

    private func drawingZoneRides(
        _ result: RouteResult,
        cache: inout [String: [Coordinates]?]
    ) async -> RouteResult {
        var legs: [RouteLeg] = []
        for leg in result.legs {
            guard leg.isZoneRide, let path = await drivingPath(for: leg, cache: &cache) else {
                legs.append(leg)
                continue
            }
            legs.append(leg.copy(polylineCoordinates: path))
        }
        return result.replacingLegs(legs)
    }

    /// One request per endpoint pair, shared across every option.
    private func drivingPath(for leg: RouteLeg, cache: inout [String: [Coordinates]?]) async -> [Coordinates]? {
        let from = leg.fromStation.coordinates, to = leg.toStation.coordinates
        let key = String(format: "%.5f,%.5f>%.5f,%.5f", from.lat, from.lng, to.lat, to.lng)
        if let cached = cache[key] { return cached }
        let path = await DirectionsGateway.shared.path(
            from: from, to: to, transport: .automobile, urgency: .interactive)?.coordinates
        if path == nil {
            directionsLog.error("zone ride \(leg.line, privacy: .public): driving path missing, leg draws nothing")
        }
        cache[key] = path
        return path
    }
}
