//
//  ExploreViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import SwiftUI
import MapKit

@Observable
@MainActor
final class ExploreViewModel {

    var layers: [RouteLayer] = [] {
        didSet {
            if let id = focusedLayerID, !layers.contains(where: { $0.id == id }) { focusedLayerID = nil }
        }
    }
    /// The route the map isolates. `nil` shows every visible route and no station dots.
    var focusedLayerID: String?
    var isLoading = false
    var errorMessage: String?
    var isDeletingLayer = false
    /// Kept separate from `errorMessage` so a failed delete doesn't get wiped by the
    /// next graph reload, and vice versa.
    var deleteError: String?

    // Road-snapped coordinates fetched via MKDirections, keyed by edge ID.
    // visiblePolylines prefers these over the static JSON coordinates.
    private var roadPolylines: [String: [CLLocationCoordinate2D]] = [:]
    // Source-geometry fingerprint of each snapped edge, used to key the disk cache.
    private var snapFingerprints: [String: UInt64] = [:]
    // Edges where at least one segment failed to snap. The disk cache never stores them.
    private var incompleteEdgeIDs: Set<String> = []
    var fetchProgress: Int = 0
    var fetchTotal: Int = 0
    var isFetchingRoads: Bool { fetchProgress < fetchTotal }
    // Incremented by every load(); a load that sees a newer value stops.
    private var loadGeneration = 0

    private var hasStarted = false

    /// Registers the graph-update observer and starts the first load, once per instance.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await load() }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("TransitDataDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.load() }
        }
    }

    // MARK: - Load

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        // roadPolylines survives reloads: re-snapping every edge on each TransitDataDidUpdate
        // fires 50+ MKDirections requests at once and hits Apple's GEO rate limit.
        fetchProgress = 0
        fetchTotal = 0

        switch await GraphStore.shared.graph() {
        case .success(let graph):
            let prepared = await ExploreLayerBuilder.prepare(
                graph: graph, modeColors: Self.modeColors, fallbackColor: .slate)
            guard generation == loadGeneration else { return }
            roadPolylines.merge(prepared.roadPolylines) { _, new in new }
            isLoading = false
            await reveal(prepared.layers, generation: generation)
            guard generation == loadGeneration else { return }
            await startRoadSnapping(prepared)
        case .failure(let err):
            errorMessage = "Failed to load graph: \(err)"
            isLoading = false
        }
    }

    /// The first load shows one layer at a time. A reload replaces the list in one step.
    private func reveal(_ newLayers: [RouteLayer], generation: Int) async {
        guard layers.isEmpty else {
            layers = newLayers
            return
        }
        for layer in newLayers {
            guard generation == loadGeneration else { return }
            layers.append(layer)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func startRoadSnapping(_ prepared: ExploreLayerBuilder.Prepared) async {
        let candidates = prepared.snapCandidates.filter { roadPolylines[$0.id] == nil }
        let liveIDs = Set(prepared.layers.flatMap { $0.polylines.map(\.id) })
        snapFingerprints = snapFingerprints.filter { liveIDs.contains($0.key) }
        for candidate in candidates { snapFingerprints[candidate.id] = candidate.fingerprint }
        let hits = await RoadSnapCache.shared.snapped(matching: snapFingerprints)
        for (id, coordinates) in hits where roadPolylines[id] == nil {
            roadPolylines[id] = coordinates
        }
        let pending = candidates.filter { roadPolylines[$0.id] == nil }
        // fetchTotal counts every consecutive coordinate pair across all pending polylines.
        fetchTotal = pending.reduce(0) { $0 + ($1.coordinates.count - 1) }
        if !pending.isEmpty { Task { await snapToRoads(edges: pending) } }
    }

    // MARK: - Road Snapping

    private func snapToRoads(edges: [ExploreLayerBuilder.SnapCandidate]) async {
        fetchProgress = 0
        struct Seg {
            let edgeID: String; let idx: Int
            let snapped: [CLLocationCoordinate2D]?
            let from: CLLocationCoordinate2D; let to: CLLocationCoordinate2D
        }
        // Flatten all (edge, segment-index) pairs so the sliding window below can schedule
        // them in order without nested loops inside the group body.
        struct SegInput {
            let edgeID: String; let idx: Int
            let from: CLLocationCoordinate2D; let to: CLLocationCoordinate2D
            let transportType: MKDirectionsTransportType
        }
        var inputs: [SegInput] = []
        for edge in edges {
            let coords = edge.coordinates
            for i in 0..<(coords.count - 1) {
                inputs.append(SegInput(edgeID: edge.id, idx: i,
                                       from: coords[i], to: coords[i + 1],
                                       transportType: edge.transportType))
            }
        }

        var byEdge: [String: [Seg]] = [:]
        var completed = 0
        // Sliding-window concurrency: keep at most maxConcurrent in-flight requests so we
        // never burst more than ~8 simultaneous MKDirections calls. Apple's GEO service
        // allows 50 per 60 s; each call takes ~1–2 s, so 8 concurrent ≈ 4–8 RPS max.
        let maxConcurrent = 8
        await withTaskGroup(of: Seg.self) { group in
            var nextIndex = 0
            // Seed the initial batch.
            while nextIndex < inputs.count && nextIndex < maxConcurrent {
                let s = inputs[nextIndex]; nextIndex += 1
                group.addTask {
                    Seg(edgeID: s.edgeID, idx: s.idx,
                        snapped: await Self.roadPolyline(from: s.from, to: s.to, transportType: s.transportType),
                        from: s.from, to: s.to)
                }
            }
            // As each task finishes, schedule the next pending segment.
            for await seg in group {
                byEdge[seg.edgeID, default: []].append(seg)
                // Batched: every completion mutating observable state re-invalidates the
                // map, which rebuilds every overlay. The counter only drives a progress
                // label, so a coarser tick costs nothing visible.
                completed += 1
                if completed % 4 == 0 || completed == inputs.count {
                    fetchProgress = completed
                }
                if nextIndex < inputs.count {
                    let s = inputs[nextIndex]; nextIndex += 1
                    group.addTask {
                        Seg(edgeID: s.edgeID, idx: s.idx,
                            snapped: await Self.roadPolyline(from: s.from, to: s.to, transportType: s.transportType),
                            from: s.from, to: s.to)
                    }
                }
            }
        }
        // Stitch each edge's segments back into one road-following polyline.
        for (edgeID, segs) in byEdge {
            var stitched: [CLLocationCoordinate2D] = []
            var isComplete = true
            for seg in segs.sorted(by: { $0.idx < $1.idx }) {
                if let snapped = seg.snapped {
                    stitched += stitched.isEmpty ? snapped : Array(snapped.dropFirst())
                } else {
                    if stitched.isEmpty { stitched.append(seg.from) }
                    stitched.append(seg.to)
                    isComplete = false
                }
            }
            if stitched.count >= 2 { roadPolylines[edgeID] = stitched }
            if isComplete { incompleteEdgeIDs.remove(edgeID) } else { incompleteEdgeIDs.insert(edgeID) }
        }
        await saveSnapCache()
    }

    /// Writes every complete snapped edge to the disk cache in one write.
    private func saveSnapCache() async {
        var entries: [String: RoadSnapCache.Entry] = [:]
        for (id, fingerprint) in snapFingerprints where !incompleteEdgeIDs.contains(id) {
            guard let coordinates = roadPolylines[id] else { continue }
            entries[id] = RoadSnapCache.Entry(fingerprint: fingerprint, coordinates: coordinates)
        }
        await RoadSnapCache.shared.replace(with: entries)
    }

    /// Snapping goes through `DirectionsGateway` at `.background` urgency. This pass is the
    /// app's heaviest MKDirections consumer — dozens of segments, eight at a time — and it
    /// used to spend the whole per-app rate limit, after which *every* other request in the
    /// app (notably a search's walk legs) came back "Directions Not Available". The gateway
    /// paces it behind interactive work and caches results across reloads.
    nonisolated private static func roadPolyline(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D]? {
        let path = await DirectionsGateway.shared.path(
            from: Coordinates(lat: from.latitude, lng: from.longitude),
            to: Coordinates(lat: to.latitude, lng: to.longitude),
            transport: transportType,
            urgency: .background
        )
        return path?.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        }
    }

    // MARK: - Layer Visibility

    func toggle(_ layerID: String) {
        guard let i = layers.firstIndex(where: { $0.id == layerID }) else { return }
        var updated = layers[i]; updated.isVisible.toggle(); layers[i] = updated
    }

    func focus(_ layerID: String) {
        guard layers.contains(where: { $0.id == layerID }) else { return }
        focusedLayerID = layerID
    }

    func clearFocus() { focusedLayerID = nil }

    /// Deletes a whole route, server first. The previous version only rewrote the local
    /// Documents JSON and swallowed every error, so the route came back on the next
    /// `GraphService` sync (the server still had it) and a failure was indistinguishable
    /// from success. Now the backend is the source of truth: the row goes only if
    /// `DELETE /api/v1/admin/graph/routes/:lineId` succeeds, and the optimistic removal
    /// is rolled back if it doesn't.
    func deleteLayer(_ layerID: String) async {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        let removed = layers[index]

        isDeletingLayer = true
        deleteError = nil
        layers.remove(at: index)
        removed.polylines.forEach {
            roadPolylines.removeValue(forKey: $0.id)
            snapFingerprints.removeValue(forKey: $0.id)
        }

        do {
            try await AdminService.shared.deleteRoute(lineId: layerID)
        } catch {
            layers.insert(removed, at: min(index, layers.count))
            deleteError = (error as? APIError)?.userMessage ?? "Couldn't delete \(removed.displayName)."
            isDeletingLayer = false
            return
        }

        // Server's done; patch the on-disk graph so routing/Commute drop the line without
        // waiting for a sync. If that write fails the server is still authoritative, so
        // pull a fresh copy rather than leaving the cache ahead of the truth.
        do {
            try await removeFromGraph(lineID: layerID)
        } catch {
            await GraphService.shared.forceSync()
        }
        isDeletingLayer = false
    }

    private func removeFromGraph(lineID: String) async throws {
        try await Self.rewriteGraphFile(removingLine: lineID)
        GraphStore.shared.invalidate()
        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }

    @concurrent
    private static func rewriteGraphFile(removingLine lineID: String) async throws {
        guard let docsURL = GraphLoader.documentsURL(),
              FileManager.default.fileExists(atPath: docsURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let sourceURL = docsURL

        let data = try Data(contentsOf: sourceURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }

        if var stations = root["stations"] as? [[String: Any]] {
            stations.removeAll { ($0["line"] as? String) == lineID }
            root["stations"] = stations
        }
        if var edges = root["edges"] as? [[String: Any]] {
            edges.removeAll { ($0["line"] as? String) == lineID }
            root["edges"] = edges
        }
        if var modes = root["transportModes"] as? [String: Any] {
            for (key, val) in modes {
                if var entry = val as? [String: Any],
                   var lines = entry["lines"] as? [String],
                   lines.contains(lineID) {
                    lines.removeAll { $0 == lineID }
                    entry["lines"] = lines
                    modes[key] = entry
                }
            }
            root["transportModes"] = modes
        }

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: docsURL, options: .atomic)
    }

    func showAll() { layers = layers.map { var l = $0; l.isVisible = true;  return l } }
    func hideAll() { layers = layers.map { var l = $0; l.isVisible = false; return l } }

    var allVisible:  Bool { layers.allSatisfy(\.isVisible) }
    var noneVisible: Bool { !layers.isEmpty && layers.allSatisfy { !$0.isVisible } }

    // MARK: - Computed Map Content

    var focusedLayer: RouteLayer? { layers.first { $0.id == focusedLayerID } }

    /// Draws only the focused route, even when its eye toggle is off. One item per edge chain.
    var visiblePolylines: [ColoredPolyline] {
        let shown = focusedLayer.map { [$0] } ?? layers.filter(\.isVisible)
        return shown.flatMap { layer in
            layer.chains.compactMap { chain -> ColoredPolyline? in
                var coords: [CLLocationCoordinate2D] = []
                for id in chain {
                    guard let index = layer.polylineIndex[id] else { continue }
                    let poly = layer.polylines[index]
                    guard poly.coordinates.count >= 2 else { continue }
                    // Road-snapped coordinates take priority; straight line is the fallback.
                    let edgeCoords = roadPolylines[id] ?? poly.coordinates
                    // The first coordinate of a later edge repeats the shared junction point.
                    coords.append(contentsOf: coords.isEmpty ? edgeCoords[...] : edgeCoords.dropFirst())
                }
                guard coords.count >= 2, let firstID = chain.first else { return nil }
                return ColoredPolyline(id: firstID, layerID: layer.id, coordinates: coords,
                                       color: layer.color, lineWidth: layer.lineWidth)
            }
        }
    }

    /// Empty without a focus. With a focus, the focused route's stations.
    var visibleStations: [VisibleStation] { focusedLayer?.stations ?? [] }

    /// Smallest map rect that holds the focused route's drawn line and stations.
    var focusedMapRect: MKMapRect? {
        guard let layer = focusedLayer else { return nil }
        let coordinates = visiblePolylines.flatMap(\.coordinates) + layer.stations.map(\.coordinate)
        return coordinates.reduce(MKMapRect.null) { rect, coordinate in
            let point = MKMapPoint(coordinate)
            return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
    }

    // MARK: - Static Helpers

    /// Mode colors keyed by raw value, read on the main actor for the off-main layer builder.
    private static var modeColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: TransportMode.allCases.map { ($0.rawValue, $0.color) })
    }

    static func modeIcon(_ mode: String) -> String {
        switch mode {
        case "train":    return "tram.fill"
        case "bus":      return "bus.fill"
        case "jeepney":  return "car.fill"
        case "uv_express": return "car.side.fill"
        case "tricycle": return "bicycle"
        default:         return "figure.walk"
        }
    }
}
