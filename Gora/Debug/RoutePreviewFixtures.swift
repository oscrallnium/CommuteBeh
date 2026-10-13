//
//  RoutePreviewFixtures.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

#if DEBUG
import Foundation

/// Sample legs for SwiftUI previews. Never read by shipping code.
enum RoutePreviewFixtures {
    static let destinationName = "Ayala Triangle Gardens"

    private static func station(_ id: String, _ name: String, line: String, type: String) -> Station {
        Station(
            id: id, name: name, shortName: name, line: line, type: type,
            coordinates: Coordinates(lat: 14.5763, lng: 121.0194),
            isTerminal: false, isInterchange: false, interchangesWith: nil, amenities: [],
            operatingHours: .init(open: "05:30", close: "23:00"), accessPoints: nil, sequence: nil, boarding: nil
        )
    }

    private static func leg(_ from: Station, _ to: Station, mode: TransportMode, line: String,
                            minutes: Double, fare: Double, km: Double, stops: Int) -> RouteLeg {
        RouteLeg(
            fromStation: from, toStation: to, mode: mode, line: line, direction: nil,
            stops: Array(repeating: from, count: stops) + [to],
            effectiveTravelMinutes: minutes, fare: fare, distanceKm: km,
            polylineCoordinates: [], estimatedArrival: Date().addingTimeInterval(minutes * 60),
            instruction: "", rawSteps: []
        )
    }

    /// Six legs, so the expanded list scrolls.
    static var legs: [RouteLeg] {
        let origin = station("P_ORIGIN", "Your location", line: "ACCESS_WALK", type: "walk")
        let ortigas = station("T_ORT", "Ortigas", line: "MRT-3", type: "train")
        let guadalupe = station("T_GUA", "Guadalupe", line: "MRT-3", type: "train")
        let bus = station("B_GUA", "Guadalupe Bus Stop", line: "EDSA_BUS", type: "bus")
        let ayala = station("B_AYA", "Ayala", line: "EDSA_BUS", type: "bus")
        let jeep = station("J_PAS", "Paseo", line: "JEEPNEY_MAKATI", type: "jeepney")
        let end = station("P_DEST", destinationName, line: "ACCESS_WALK", type: "walk")
        return [
            leg(origin, ortigas, mode: .walk, line: "ACCESS_WALK", minutes: 4, fare: 0, km: 0.3, stops: 1),
            leg(ortigas, guadalupe, mode: .train, line: "MRT-3", minutes: 9, fare: 16, km: 4.2, stops: 3),
            leg(guadalupe, bus, mode: .walk, line: "INTERCHANGE", minutes: 3, fare: 0, km: 0.2, stops: 1),
            leg(bus, ayala, mode: .bus, line: "EDSA_BUS", minutes: 12, fare: 20, km: 3.1, stops: 2),
            leg(ayala, jeep, mode: .jeepney, line: "JEEPNEY_MAKATI", minutes: 7, fare: 14, km: 1.4, stops: 2),
            leg(jeep, end, mode: .walk, line: "ACCESS_WALK", minutes: 5, fare: 0, km: 0.4, stops: 1),
        ]
    }

    static var legRows: [CommuteLegRowModel] {
        legs.map { CommuteLegRowModel(leg: $0, lineName: { $0 }, legColor: { $0.mode.color }) }
    }
}
#endif
