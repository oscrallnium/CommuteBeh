//
//  SearchAnalytics.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/21/26.
//

import CoreLocation
import FirebaseAnalytics
import Foundation

/// Logs one anonymous `route_search` event per completed search. Each endpoint is a station
/// ID from the graph, never a coordinate, address, or place name.
enum SearchAnalytics {
    private enum Event {
        static let routeSearch = "route_search"
        static let originStop = "origin_stop"
        static let destinationStop = "destination_stop"
        static let optionCount = "option_count"
        static let modes = "modes"
        static let scheduledTime = "scheduled_time"
        static let result = "result"
        static let found = "found"
        static let none = "none"
        static let outsideNetwork = "outside_network"
        static let modeSeparator = ","
    }

    static let outsideNetworkStop = Event.outsideNetwork

    static func logRouteSearch(
        originStop: String,
        destinationStop: String,
        options: [RouteOption],
        scheduledTime: Bool
    ) {
        Analytics.logEvent(Event.routeSearch, parameters: [
            Event.originStop: originStop,
            Event.destinationStop: destinationStop,
            Event.optionCount: options.count,
            Event.modes: modes(of: options.first),
            Event.scheduledTime: scheduledTime ? 1 : 0,
            Event.result: options.isEmpty ? Event.none : Event.found
        ])
    }

    private static func modes(of option: RouteOption?) -> String {
        guard let legs = option?.result.legs else { return "" }
        var modes: [String] = []
        for leg in legs where modes.last != leg.mode.rawValue {
            modes.append(leg.mode.rawValue)
        }
        return modes.joined(separator: Event.modeSeparator)
    }
}

extension TransitGraphEngine {
    /// ID of the station nearest to `coordinate`, or `nil` when no station lies within the
    /// access-walk ceiling.
    func nearestStationID(to coordinate: Coordinates) -> StationID? {
        let ceilingMeters = AccessPolicy.hardCeilingKm * 1000
        let point = CLLocation(latitude: coordinate.lat, longitude: coordinate.lng)
        return stationGrid.indices(near: coordinate, radiusKm: AccessPolicy.hardCeilingKm)
            .map { (station: stationList[$0], meters: point.distance(from: CLLocation(
                latitude: stationList[$0].coordinates.lat, longitude: stationList[$0].coordinates.lng))) }
            .filter { $0.meters <= ceilingMeters }
            .min { $0.meters < $1.meters }?
            .station.id
    }
}

extension RouteStore {
    /// Resolves both endpoints to station IDs and logs the finished search.
    func logRouteSearch(engine: TransitGraphEngine, options: [RouteOption]) async {
        let origin = await stopID(for: originCoordinate, stationID: originID, engine: engine)
        let destination = await stopID(for: destinationCoordinate, stationID: destinationID, engine: engine)
        SearchAnalytics.logRouteSearch(
            originStop: origin, destinationStop: destination,
            options: options, scheduledTime: useScheduledTime)
    }

    private func stopID(for coordinate: Coordinates?, stationID: StationID, engine: TransitGraphEngine) async -> String {
        guard let coordinate else { return stationID }
        return await engine.nearestStationID(to: coordinate) ?? SearchAnalytics.outsideNetworkStop
    }
}
