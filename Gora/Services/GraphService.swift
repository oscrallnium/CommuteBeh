//
//  GraphService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import Foundation
import OSLog

final class GraphService {
    static let shared = GraphService()
    private let client = APIClient.shared
    private let log = Logger(subsystem: "com.banaueinc.gora", category: "GraphSync")

    /// Why the last sync attempt failed, or `nil` if it succeeded / never ran.
    ///
    /// A failed sync leaves the app routing on whatever graph is already in Documents, and
    /// a stale graph is indistinguishable from a genuine routing failure — "no route found"
    /// for a trip that a newer graph covers. Recording the reason is what makes the two
    /// tellable apart; the admin screen surfaces it and the log line carries it regardless.
    private(set) var lastSyncError: String?

    private init() {}

    func currentVersion() async throws -> GraphVersion {
        let resp: APIResponse<GraphVersion> = try await client.request(
            .graphVersion,
            responseType: APIResponse<GraphVersion>.self
        )
        return resp.data
    }

    // Downloads the graph from the backend and decodes it off the main actor.
    // Uses APIClient so auth headers are handled; the { "data": {...} } unwrapping happens here.
    func fetchGraph() async throws -> TransitGraph {
        let data = try await client.requestData(.graph)
        return try await Self.decodeGraph(data)
    }

    @concurrent
    private static func decodeGraph(_ data: Data) async throws -> TransitGraph {
        do {
            return try APIClient.makeDecoder().decode(APIResponse<TransitGraph>.self, from: data).data
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    // Checks remote version against the currently loaded graph version.
    // If different, fetches, hands the graph to GraphStore, and posts TransitDataDidUpdate
    // so CommuteViewModel reloads the engine with fresh data.
    @discardableResult
    func syncIfNeeded(loadedVersion: String) async -> Bool {
        do {
            let remote = try await currentVersion()
            guard remote.version != loadedVersion else {
                lastSyncError = nil
                return true
            }
            log.info("Graph \(loadedVersion, privacy: .public) → \(remote.version, privacy: .public); downloading")
            return await download()
        } catch {
            return fail("version check failed: \(error.localizedDescription)")
        }
    }

    // Forces an unconditional graph re-download and reloads the engine.
    // Used after an admin setting change that bumps the graph version server-side.
    @discardableResult
    func forceSync() async -> Bool {
        await download()
    }

    // MARK: Private

    private func download() async -> Bool {
        let graph: TransitGraph
        do {
            graph = try await fetchGraph()
        } catch {
            return fail("download failed: \(error.localizedDescription)")
        }
        do {
            try await GraphStore.shared.replace(graph)
        } catch {
            return fail("cache write failed: \(error.localizedDescription)")
        }
        lastSyncError = nil
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
        }
        return true
    }

    private func fail(_ reason: String) -> Bool {
        lastSyncError = reason
        log.error("Graph sync \(reason, privacy: .public) — continuing on the cached graph")
        return false
    }
}
