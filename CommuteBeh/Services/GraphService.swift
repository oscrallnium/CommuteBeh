//
//  GraphService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import Foundation

final class GraphService {
    static let shared = GraphService()
    private let client = APIClient.shared

    private init() {}

    func currentVersion() async throws -> GraphVersion {
        let resp: APIResponse<GraphVersion> = try await client.request(
            .graphVersion,
            responseType: APIResponse<GraphVersion>.self
        )
        return resp.data
    }

    // Downloads the graph from the backend and re-encodes it as camelCase JSON
    // suitable for GraphLoader.load() (which uses the default JSONDecoder).
    // Uses APIClient so auth headers and the { "data": {...} } unwrapping are handled.
    func fetchGraph() async throws -> Data {
        let resp: APIResponse<TransitGraph> = try await client.request(
            .graph,
            responseType: APIResponse<TransitGraph>.self
        )
        return try JSONEncoder().encode(resp.data)
    }

    // Checks remote version against the currently loaded graph version.
    // If different, fetches, caches to Documents, and posts TransitDataDidUpdate
    // so CommuteViewModel reloads the engine with fresh data.
    func syncIfNeeded(loadedVersion: String) async {
        guard let remote = try? await currentVersion() else { return }
        guard remote.version != loadedVersion else { return }
        guard let data = try? await fetchGraph() else { return }
        guard let url = GraphLoader.documentsURL() else { return }
        try? data.write(to: url)
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
        }
    }

    // Forces an unconditional graph re-download and reloads the engine.
    // Used after an admin setting change that bumps the graph version server-side.
    func forceSync() async {
        guard let data = try? await fetchGraph(),
              let url = GraphLoader.documentsURL() else { return }
        try? data.write(to: url)
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
        }
    }
}
