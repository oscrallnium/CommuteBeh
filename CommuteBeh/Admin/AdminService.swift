//
//  AdminService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import Foundation

final class AdminService {
    static let shared = AdminService()
    private let client = APIClient.shared

    private init() {}

    func updateStation(id: String, update: StationUpdate) async throws -> Station {
        let resp: APIResponse<Station> = try await client.request(
            .updateStation(id: id, update: update),
            responseType: APIResponse<Station>.self
        )
        return resp.data
    }

    func updateEdge(id: String, polylineCoordinates: [Coordinates]) async throws -> TransitEdge {
        let resp: APIResponse<TransitEdge> = try await client.request(
            .updateEdge(id: id, polylineCoordinates: polylineCoordinates),
            responseType: APIResponse<TransitEdge>.self
        )
        return resp.data
    }

    func deleteRoute(lineId: String) async throws {
        _ = try await client.request(.deleteRoute(lineId: lineId), responseType: EmptyResponse.self)
    }

    func fetchSettings() async throws -> AdminSettings {
        let resp: APIResponse<AdminSettings> = try await client.request(
            .adminSettings,
            responseType: APIResponse<AdminSettings>.self
        )
        return resp.data
    }

    func updateSettings(enforceOperatingHours: Bool) async throws -> AdminSettings {
        let resp: APIResponse<AdminSettings> = try await client.request(
            .updateAdminSettings(enforceOperatingHours: enforceOperatingHours),
            responseType: APIResponse<AdminSettings>.self
        )
        return resp.data
    }
}
