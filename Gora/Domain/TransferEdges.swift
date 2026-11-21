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
    /// Longest walk to or from a tricycle zone terminal. Riders accept a longer walk to a terminal.
    static let terminalMaxKm: Double = 0.5
    /// Time added to every transfer for finding the next stop and boarding.
    static let boardingMinutes: Double = 3
    /// Search-only cost of a change of vehicle: a second fare, a new seat, and the risk of a missed vehicle.
    static let searchPenaltyMinutes: Double = 5

    /// Search-only wait for the next vehicle of `mode`: half a typical headway, because the graph has no frequency data.
    static func expectedWaitMinutes(for mode: TransportMode?) -> Double {
        guard let mode else { return 0 }
        switch mode {
        case .bus, .uvExpress: return 5
        case .jeepney, .modernJeepney: return 3
        case .train: return 2.5
        case .tricycle: return 2
        case .walk: return 0
        }
    }

    /// One edge in each direction for every close pair on different chains that no dashboard
    /// transfer covers in that direction. The edges use the `INTERCHANGE` line, so they never merge
    /// into a ride and carry no fare. A grid limits each station to its nearby cells. A pair that
    /// includes a station of `zoneTerminalIDs` uses `terminalMaxKm`; any other pair uses `maxKm`.
    static func edges(
        stations: [Station],
        existing: [TransitEdge],
        walkModeID: String,
        zoneTerminalIDs: Set<StationID> = []
    ) -> [TransitEdge] {
        let linked = Set(existing.filter(\.isDashboardTransfer).flatMap {
            $0.bidirectional ? [pairKey($0.from, $0.to), pairKey($0.to, $0.from)] : [pairKey($0.from, $0.to)]
        })
        let located = stations.map {
            ($0, CLLocation(latitude: $0.coordinates.lat, longitude: $0.coordinates.lng))
        }
        let chainKeys = stations.map(StationChain.key(of:))
        let grid = StationGrid(coordinates: stations.map(\.coordinates), cellKm: maxKm)

        let queryKm = zoneTerminalIDs.isEmpty ? maxKm : terminalMaxKm

        var result: [TransitEdge] = []
        for (i, (a, locationA)) in located.enumerated() {
            for j in grid.indices(near: a.coordinates, radiusKm: queryKm) where j > i && chainKeys[i] != chainKeys[j] {
                let (b, locationB) = located[j]
                let km = locationA.distance(from: locationB) / 1000
                let limitKm = zoneTerminalIDs.contains(a.id) || zoneTerminalIDs.contains(b.id) ? terminalMaxKm : maxKm
                guard km <= limitKm else { continue }
                if !linked.contains(pairKey(a.id, b.id)) {
                    result.append(transfer(from: a, to: b, km: km, walkModeID: walkModeID))
                }
                if !linked.contains(pairKey(b.id, a.id)) {
                    result.append(transfer(from: b, to: a, km: km, walkModeID: walkModeID))
                }
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
