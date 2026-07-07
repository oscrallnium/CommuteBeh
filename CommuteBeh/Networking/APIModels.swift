//
//  APIModels.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import Foundation

// Wrapper used by all authenticated endpoints
struct APIResponse<T: Decodable>: Decodable {
    let data: T
}

struct EmptyResponse: Decodable {}

// MARK: - Auth

struct AuthPayload: Decodable {
    let token: String
    let user: UserProfile
}

// Codable (not just Decodable) so we can persist to UserDefaults
struct UserProfile: Codable {
    let id: String
    let email: String
    let displayName: String
    let role: String
    let homeStationId: String?
}

// MARK: - Admin

struct AdminSettings: Decodable {
    let enforceOperatingHours: Bool

    enum CodingKeys: String, CodingKey {
        case enforceOperatingHours = "enforce_operating_hours"
    }
}

/// Fields that can be patched on a station via PATCH /api/v1/admin/stations/:id.
/// All properties are optional — only non-nil values are sent to the server.
struct StationUpdate {
    var latitude: Double?
    var longitude: Double?
    var name: String?
    var shortName: String?
    var openTime: String?
    var closeTime: String?
}

// MARK: - Transit

struct APIRoute: Decodable {
    let lineId: String
    let name: String
    let color: String?
}

struct SavedRoute: Decodable {
    let id: String
    let name: String
    let originStationId: String
    let destinationStationId: String
    let lineIds: [String]
    let createdAt: String
}

struct Incident: Decodable {
    let id: String
    let stationId: String
    let description: String
    let category: String
    let reportedAt: String
}

struct GraphVersion: Decodable {
    let version: String     // stored as String internally; backend returns Int
    let lastModified: String

    enum CodingKeys: String, CodingKey { case version, lastModified }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intV = try? c.decode(Int.self, forKey: .version) {
            version = String(intV)
        } else {
            version = try c.decode(String.self, forKey: .version)
        }
        lastModified = try c.decode(String.self, forKey: .lastModified)
    }
}
