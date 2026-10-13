//
//  SavedPlace.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// The icon a saved place shows on its chip. The raw value is the stored JSON string.
nonisolated enum SavedPlaceIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case house, briefcase, graduationcap, heart, star, mappin

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .house: "house.fill"
        case .briefcase: "briefcase.fill"
        case .graduationcap: "graduationcap.fill"
        case .heart: "heart.fill"
        case .star: "star.fill"
        case .mappin: "mappin"
        }
    }
}

/// A place the passenger saved for one-tap destination entry. Encodes with `ARSurveyCoding`
/// (snake_case keys, ISO 8601 dates). `stationId` is set only when the place is a station.
nonisolated struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var icon: SavedPlaceIcon
    var addressLabel: String
    var coordinates: Coordinates
    var stationId: StationID?
    let createdAt: Date
    var updatedAt: Date
}
