//
//  RouteService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import Foundation

final class RouteService {
    static let shared = RouteService()
    private let client = APIClient.shared

    private init() {}

    func stations(query: String? = nil) async throws -> [Station] {
        let resp: APIResponse<[Station]> = try await client.request(
            .stations(query: query),
            responseType: APIResponse<[Station]>.self
        )
        return resp.data
    }

    func routes() async throws -> [APIRoute] {
        let resp: APIResponse<[APIRoute]> = try await client.request(
            .routes,
            responseType: APIResponse<[APIRoute]>.self
        )
        return resp.data
    }

    func savedRoutes() async throws -> [SavedRoute] {
        let resp: APIResponse<[SavedRoute]> = try await client.request(
            .savedRoutes,
            responseType: APIResponse<[SavedRoute]>.self
        )
        return resp.data
    }

    func saveRoute(name: String, origin: String, destination: String, lineIds: [String]) async throws -> SavedRoute {
        let resp: APIResponse<SavedRoute> = try await client.request(
            .createSavedRoute(name: name, origin: origin, destination: destination, lineIds: lineIds),
            responseType: APIResponse<SavedRoute>.self
        )
        return resp.data
    }

    func deleteSavedRoute(id: String) async throws {
        _ = try await client.request(.deleteSavedRoute(id: id), responseType: EmptyResponse.self)
    }
}
