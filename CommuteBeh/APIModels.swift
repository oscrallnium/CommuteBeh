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

struct UserProfile: Decodable {
    let id: String
    let email: String
    let displayName: String
    let role: String
    let homeStationId: String?
}

// MARK: - Transit

// Prefixed to avoid collision with the local domain Station type in TransportMode.swift
struct APIStation: Decodable {
    let stationId: String
    let name: String
    let latitude: Double
    let longitude: Double
    let lineIds: [String]
    let isTerminal: Bool
}

// Prefixed for consistency with APIStation
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
    let version: String
    let updatedAt: String
}
