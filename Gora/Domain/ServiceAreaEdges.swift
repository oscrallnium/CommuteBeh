//
//  ServiceAreaEdges.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/5/26.
//

import CoreLocation

/// A tricycle zone. A rider boards at a terminal and leaves anywhere inside `boundary`.
/// Every number except `boundary` and `terminalIds` is optional in the JSON.
nonisolated struct ServiceArea: Codable, Sendable {
    let line: String
    let mode: String
    let boundary: [Coordinates]
    let terminalIds: [StationID]
    let baseFare: Double
    let baseKm: Double
    let farePerKm: Double
    let speedKmh: Double
    let detourFactor: Double
    let waitMinutes: Double
    let acceptedPayments: [String]

    private enum CodingKeys: String, CodingKey {
        case line, mode, boundary, terminalIds, baseFare, baseKm, farePerKm
        case speedKmh, detourFactor, waitMinutes, acceptedPayments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line             = try c.decode(String.self,        forKey: .line)
        mode             = try c.decode(String.self,        forKey: .mode)
        boundary         = try c.decode([Coordinates].self, forKey: .boundary)
        terminalIds      = try c.decode([StationID].self,   forKey: .terminalIds)
        baseFare         = try c.decodeIfPresent(Double.self,   forKey: .baseFare) ?? 0
        baseKm           = try c.decodeIfPresent(Double.self,   forKey: .baseKm) ?? 0
        farePerKm        = try c.decodeIfPresent(Double.self,   forKey: .farePerKm) ?? 0
        speedKmh         = try c.decodeIfPresent(Double.self,   forKey: .speedKmh) ?? 15
        detourFactor     = try c.decodeIfPresent(Double.self,   forKey: .detourFactor) ?? 1.3
        waitMinutes      = try c.decodeIfPresent(Double.self,   forKey: .waitMinutes) ?? 0
        acceptedPayments = try c.decodeIfPresent([String].self, forKey: .acceptedPayments) ?? []
    }

    /// True when `point` lies inside the boundary polygon (even-odd rule).
    func contains(_ point: Coordinates) -> Bool {
        var inside = false
        var previous = boundary.count - 1
        for index in boundary.indices {
            let a = boundary[index], b = boundary[previous]
            if (a.lat > point.lat) != (b.lat > point.lat),
               point.lng < (b.lng - a.lng) * (point.lat - a.lat) / (b.lat - a.lat) + a.lng {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }
}

/// Builds the one-way tricycle rides of each zone. A rider boards only at a terminal and
/// leaves at any station inside the zone, terminals included.
nonisolated enum ServiceAreaPolicy {
    private static let idPrefix = "ZONE_"
    private static let crowdFactor = 0.2
    private static let reliability = 0.9

    /// One edge from each terminal to every other terminal and to every station inside the zone.
    /// No edge leaves a non-terminal station.
    static func edges(areas: [ServiceArea], stations: [Station]) -> [TransitEdge] {
        var result: [TransitEdge] = []
        for area in areas {
            let terminals = stations.filter { area.terminalIds.contains($0.id) }
            guard !terminals.isEmpty, let box = Box(area.boundary) else { continue }
            let inside = stations.filter {
                !area.terminalIds.contains($0.id) && box.contains($0.coordinates) && area.contains($0.coordinates)
            }
            let stops = terminals + inside
            for terminal in terminals {
                for stop in stops where stop.id != terminal.id {
                    result.append(ride(area, from: terminal.id, fromAt: terminal.coordinates,
                                       to: stop.id, toAt: stop.coordinates))
                }
            }
        }
        return result
    }

    /// One edge from each terminal of every zone that holds `destination` to the virtual node.
    static func destinationEdges(
        areas: [ServiceArea],
        stations: [StationID: Station],
        destination: Coordinates,
        destinationID: StationID
    ) -> [TransitEdge] {
        areas.filter { $0.contains(destination) }.flatMap { area in
            area.terminalIds.compactMap { stations[$0] }.map {
                ride(area, from: $0.id, fromAt: $0.coordinates, to: destinationID, toAt: destination)
            }
        }
    }

    private static func ride(
        _ area: ServiceArea,
        from: StationID, fromAt: Coordinates,
        to: StationID, toAt: Coordinates
    ) -> TransitEdge {
        let straightKm = CLLocation(latitude: fromAt.lat, longitude: fromAt.lng)
            .distance(from: CLLocation(latitude: toAt.lat, longitude: toAt.lng)) / 1000
        let roadKm = straightKm * area.detourFactor
        return TransitEdge(
            id: "\(idPrefix)\(area.line)_\(from)_\(to)",
            from: from, to: to,
            mode: area.mode, line: area.line,
            travelTimeMinutes: roadKm / area.speedKmh * 60 + area.waitMinutes,
            distanceKm: roadKm,
            // The whole fare sits in `baseFare` with `farePerKm` 0, so the leg fare is this value.
            baseFare: area.baseFare + max(0, roadKm - area.baseKm) * area.farePerKm,
            farePerKm: 0,
            acceptedPayments: area.acceptedPayments,
            isAirConditioned: false,
            crowdFactor: crowdFactor, reliability: reliability,
            bidirectional: false, direction: nil,
            // Empty, never a straight chord: a chord would draw a path through buildings.
            polylineCoordinates: [],
            mkDirectionsTransportType: "automobile",
            isRoadSnapped: false
        )
    }

    /// True for an edge that `edges` or `destinationEdges` built.
    static func isRide(_ edge: TransitEdge) -> Bool { edge.id.hasPrefix(idPrefix) }

    /// The bounding box of a boundary, a cheap test before the polygon test.
    private struct Box {
        let minLat, maxLat, minLng, maxLng: Double

        init?(_ points: [Coordinates]) {
            guard let first = points.first else { return nil }
            minLat = points.reduce(first.lat) { min($0, $1.lat) }
            maxLat = points.reduce(first.lat) { max($0, $1.lat) }
            minLng = points.reduce(first.lng) { min($0, $1.lng) }
            maxLng = points.reduce(first.lng) { max($0, $1.lng) }
        }

        func contains(_ p: Coordinates) -> Bool {
            p.lat >= minLat && p.lat <= maxLat && p.lng >= minLng && p.lng <= maxLng
        }
    }
}

extension TransitEdge {
    /// True for a tricycle zone ride edge.
    nonisolated var isZoneRide: Bool { ServiceAreaPolicy.isRide(self) }
}
