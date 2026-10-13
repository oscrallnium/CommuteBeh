//
//  TransferEdges.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/8/26.
//

import CoreLocation

/// Builds walking transfers between close stations on different lines, or on different stop
/// chains of one line, such as its northbound and southbound stops. A* can only change
/// vehicles along an edge, so a chain without these edges is reachable only from the trip's ends.
nonisolated enum TransferPolicy {
    /// Longest walk between two stations that counts as a transfer.
    static let maxKm: Double = 0.3
    /// Time added to every transfer for finding the next stop and boarding.
    static let boardingMinutes: Double = 3

    /// One edge in each direction for every close pair on different chains that has no
    /// `INTERCHANGE` edge yet. The edges use the `INTERCHANGE` line, so they never merge
    /// into a ride and carry no fare. The pair scan is quadratic in the station count.
    static func edges(
        stations: [Station],
        existing: [TransitEdge],
        walkModeID: String
    ) -> [TransitEdge] {
        let linked = Set(existing.filter { $0.line == "INTERCHANGE" }.flatMap {
            [pairKey($0.from, $0.to), pairKey($0.to, $0.from)]
        })
        let located = stations.map {
            ($0, CLLocation(latitude: $0.coordinates.lat, longitude: $0.coordinates.lng))
        }

        var result: [TransitEdge] = []
        for (i, (a, locationA)) in located.enumerated() {
            for (b, locationB) in located[(i + 1)...] where StationChain.key(of: a) != StationChain.key(of: b) {
                guard !linked.contains(pairKey(a.id, b.id)) else { continue }
                let km = locationA.distance(from: locationB) / 1000
                guard km <= maxKm else { continue }
                result.append(transfer(from: a, to: b, km: km, walkModeID: walkModeID))
                result.append(transfer(from: b, to: a, km: km, walkModeID: walkModeID))
            }
        }
        return result
    }

    private static func pairKey(_ from: StationID, _ to: StationID) -> String {
        "\(from)|\(to)"
    }

    private static func transfer(from: Station, to: Station, km: Double, walkModeID: String) -> TransitEdge {
        TransitEdge(
            id: "TRANSFER_\(from.id)_\(to.id)",
            from: from.id, to: to.id,
            mode: walkModeID, line: "INTERCHANGE",
            travelTimeMinutes: AccessPolicy.walkMinutes(forKm: km) + boardingMinutes,
            distanceKm: km,
            baseFare: 0, farePerKm: 0,
            acceptedPayments: [],
            isAirConditioned: false,
            crowdFactor: 0, reliability: 1.0,
            bidirectional: false, direction: nil,
            // Empty, never a straight chord: WalkRouteRefiner fills a walk leg from walking
            // directions, and a chord would draw a path through buildings.
            polylineCoordinates: [],
            mkDirectionsTransportType: "walking",
            isRoadSnapped: false
        )
    }
}
