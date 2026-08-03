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

    /// Inserts a new stop immediately before/after `referenceStationId` on the same
    /// line. Payload keys: referenceStationId, position ("before"/"after"), name,
    /// lat, lng, and optionally shortName/openTime/closeTime.
    func insertStation(payload: [String: Any]) async throws -> InsertStationResult {
        let resp: APIResponse<InsertStationResult> = try await client.request(
            .insertStation(payload: payload), responseType: APIResponse<InsertStationResult>.self
        )
        return resp.data
    }

    func deleteStation(id: String) async throws {
        _ = try await client.request(.deleteStation(id: id), responseType: EmptyResponse.self)
    }

    func updateEdge(
        id: String,
        polylineCoordinates: [Coordinates]? = nil,
        bidirectional: Bool? = nil,
        direction: String?? = nil
    ) async throws -> TransitEdge {
        let resp: APIResponse<TransitEdge> = try await client.request(
            .updateEdge(id: id, polylineCoordinates: polylineCoordinates,
                        bidirectional: bidirectional, direction: direction),
            responseType: APIResponse<TransitEdge>.self
        )
        return resp.data
    }

    func createRoute(payload: [String: Any]) async throws -> CreateRouteResult {
        let resp: APIResponse<CreateRouteResult> = try await client.request(
            .createRoute(payload: payload),
            responseType: APIResponse<CreateRouteResult>.self
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
