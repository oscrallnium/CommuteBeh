//
//  GraphStore.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import Foundation

/// Holds the one decoded `TransitGraph` per graph version. Every reader gets the same value,
/// and the file read, JSON decode, and file write run off the main actor.
/// Callers that change the graph file call `replace(_:)` or `invalidate()`.
@MainActor
final class GraphStore {
    static let shared = GraphStore()

    /// The decoded graph, or `nil` until the first `graph()` call finishes.
    private(set) var cachedGraph: TransitGraph?

    private var inFlight: Task<Result<TransitGraph, GraphLoadError>, Never>?
    private var generation = 0

    private init() {}

    /// Returns the cached graph. Callers that arrive during a load wait on the same load.
    func graph() async -> Result<TransitGraph, GraphLoadError> {
        if let cachedGraph { return .success(cachedGraph) }
        let startGeneration = generation
        let result = await (inFlight ?? startLoad()).value
        guard startGeneration == generation else { return await graph() }
        return result
    }

    /// Writes `graph` to the Documents file off the main actor, then makes it the cached value.
    /// The cache keeps its old value when the write throws.
    func replace(_ graph: TransitGraph) async throws {
        try await Self.write(graph)
        generation += 1
        inFlight = nil
        cachedGraph = graph
    }

    /// Drops the cached value so the next `graph()` call reads the file again.
    func invalidate() {
        generation += 1
        inFlight = nil
        cachedGraph = nil
    }

    /// Builds the engine off the main actor, because its init builds the adjacency lists.
    @concurrent
    static func makeEngine(for graph: TransitGraph) async -> TransitGraphEngine {
        TransitGraphEngine(graph: graph)
    }

    // MARK: Private

    private func startLoad() -> Task<Result<TransitGraph, GraphLoadError>, Never> {
        let startGeneration = generation
        let task = Task {
            let result = await Self.loadFromDiskOrNetwork()
            finishLoad(result, startedIn: startGeneration)
            return result
        }
        inFlight = task
        return task
    }

    private func finishLoad(_ result: Result<TransitGraph, GraphLoadError>, startedIn startGeneration: Int) {
        guard startGeneration == generation else { return }
        inFlight = nil
        if case .success(let graph) = result { cachedGraph = graph }
    }

    /// Reads the Documents file. A missing or corrupt file triggers a download that is cached to disk.
    @concurrent
    private static func loadFromDiskOrNetwork() async -> Result<TransitGraph, GraphLoadError> {
        if case .success(let graph) = GraphLoader.load() { return .success(graph) }
        guard let graph = try? await GraphService.shared.fetchGraph() else {
            return .failure(.fileNotFound)
        }
        try? writeFile(graph)
        return .success(graph)
    }

    @concurrent
    private static func write(_ graph: TransitGraph) async throws {
        try writeFile(graph)
    }

    nonisolated private static func writeFile(_ graph: TransitGraph) throws {
        guard let url = GraphLoader.documentsURL() else { throw URLError(.fileDoesNotExist) }
        try JSONEncoder().encode(graph).write(to: url, options: .atomic)
    }
}
