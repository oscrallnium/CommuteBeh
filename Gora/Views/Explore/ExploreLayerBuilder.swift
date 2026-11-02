//
//  ExploreLayerBuilder.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/18/26.
//

import SwiftUI
import MapKit

/// Builds the Explore map layers from the graph, off the main actor.
nonisolated enum ExploreLayerBuilder {

    /// One edge that needs road snapping, with the fingerprint of its source geometry.
    nonisolated struct SnapCandidate: Sendable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let transportType: MKDirectionsTransportType
        let fingerprint: UInt64
    }

    nonisolated struct Prepared: Sendable {
        let layers: [RouteLayer]
        /// Polylines of edges whose stored geometry is already road-traced, keyed by edge ID.
        let roadPolylines: [String: [CLLocationCoordinate2D]]
        let snapCandidates: [SnapCandidate]
    }

    /// Points closer together than this form a recorded trace, not a chord to snap.
    private static let denseSpacingMeters: Double = 150

    /// Runs every CPU-heavy step of an Explore load. `modeColors` is keyed by mode raw value.
    @concurrent
    static func prepare(
        graph: TransitGraph,
        modeColors: [String: Color],
        fallbackColor: Color
    ) async -> Prepared {
        let layers = buildLayers(from: graph, modeColors: modeColors, fallbackColor: fallbackColor)

        var roadPolylines: [String: [CLLocationCoordinate2D]] = [:]
        for edge in graph.edges where edge.isRoadSnapped == true {
            let coords = edge.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            if coords.count >= 2 { roadPolylines[edge.id] = coords }
        }

        // Trains run on guideways, so their JSON polylines stay unsnapped. Every other edge
        // snaps with the type its own data asks for. See DirectionsTransport.
        let candidates = layers.flatMap { layer -> [SnapCandidate] in
            guard layer.mode != "train" else { return [] }
            return layer.polylines.compactMap { poly in
                guard poly.coordinates.count >= 2,
                      roadPolylines[poly.id] == nil,
                      needsRoadSnapping(poly.coordinates) else { return nil }
                let transportType = DirectionsTransport.snapType(for: poly.transportHint)
                return SnapCandidate(
                    id: poly.id, coordinates: poly.coordinates, transportType: transportType,
                    fingerprint: RoadSnapCache.fingerprint(
                        coordinates: poly.coordinates, transportType: transportType))
            }
        }
        return Prepared(layers: layers, roadPolylines: roadPolylines, snapCandidates: candidates)
    }

    /// Whether the average point spacing is wide enough that snapping adds real road geometry.
    /// Snapping costs one MKDirections request per point pair, so dense traces are skipped.
    static func needsRoadSnapping(_ coordinates: [CLLocationCoordinate2D]) -> Bool {
        guard coordinates.count >= 2 else { return false }
        let total = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        return total / Double(coordinates.count - 1) > denseSpacingMeters
    }

    // MARK: - Graph → Layers

    private static func buildLayers(
        from graph: TransitGraph,
        modeColors: [String: Color],
        fallbackColor: Color
    ) -> [RouteLayer] {
        var stationsByLine: [String: [Station]] = [:]
        for station in graph.stations {
            stationsByLine[station.line, default: []].append(station)
        }

        var groups: [String: (mode: String, edges: [TransitEdge])] = [:]
        for edge in graph.edges where edge.mode != "walk" && edge.line != "INTERCHANGE" {
            var entry = groups[edge.line] ?? (mode: edge.mode, edges: [])
            entry.edges.append(edge)
            groups[edge.line] = entry
        }

        return groups
            .map { line, value -> RouteLayer in
                let color = graph.lineColor(for: line) ?? modeColors[value.mode] ?? fallbackColor
                let baseSize = dotSize(for: value.mode)

                // polylineCoordinates already starts with the from-station coord
                // and ends with the to-station coord (guaranteed by the JSON schema).
                let polylines: [ExplorePolyline] = value.edges.map { edge in
                    let coords = edge.polylineCoordinates.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                    return ExplorePolyline(id: edge.id, coordinates: coords,
                                           transportHint: edge.mkDirectionsTransportType)
                }

                let chains = edgeChains(for: value.edges)
                let stations: [VisibleStation] = (stationsByLine[line] ?? []).map { s in
                    VisibleStation(
                        id: s.id,
                        coordinate: CLLocationCoordinate2D(latitude: s.coordinates.lat, longitude: s.coordinates.lng),
                        color: color,
                        dotSize: (s.isInterchange || s.isTerminal) ? baseSize + 3 : baseSize,
                        isInterchange: s.isInterchange,
                        isTerminal: s.isTerminal
                    )
                }

                return RouteLayer(
                    id: line, mode: value.mode,
                    displayName: displayName(for: line, in: graph),
                    color: color, lineWidth: lineWidth(for: value.mode),
                    polylines: polylines,
                    polylineIndex: Dictionary(polylines.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }),
                    chains: chains, stations: stations
                )
            }
            .sorted { modeOrder($0.mode) < modeOrder($1.mode) }
    }

    // MARK: - Chains

    private struct StationPair: Hashable {
        let from: StationID
        let to: StationID
    }

    /// Groups edges into maximal chains of edge IDs in path order, so the map draws one
    /// polyline per chain. An edge whose reverse pair is already kept draws the same line and is dropped.
    /// A chain never continues through a station that has more than one kept edge in or out.
    static func edgeChains(for edges: [TransitEdge]) -> [[String]] {
        var seenPairs = Set<StationPair>()
        var kept: [TransitEdge] = []
        for edge in edges where !seenPairs.contains(StationPair(from: edge.to, to: edge.from)) {
            seenPairs.insert(StationPair(from: edge.from, to: edge.to))
            kept.append(edge)
        }

        var incoming: [StationID: Int] = [:]
        var outgoing: [StationID: Int] = [:]
        var firstOutgoing: [StationID: Int] = [:]
        for (index, edge) in kept.enumerated() {
            incoming[edge.to, default: 0] += 1
            outgoing[edge.from, default: 0] += 1
            if firstOutgoing[edge.from] == nil { firstOutgoing[edge.from] = index }
        }

        var successor = [Int?](repeating: nil, count: kept.count)
        var hasPredecessor = [Bool](repeating: false, count: kept.count)
        for (index, edge) in kept.enumerated() {
            guard incoming[edge.to] == 1, outgoing[edge.to] == 1,
                  let next = firstOutgoing[edge.to], next != index else { continue }
            successor[index] = next
            hasPredecessor[next] = true
        }

        var visited = [Bool](repeating: false, count: kept.count)
        func chain(startingAt start: Int) -> [String] {
            var ids: [String] = []
            var current: Int? = start
            while let index = current, !visited[index] {
                visited[index] = true
                ids.append(kept[index].id)
                current = successor[index]
            }
            return ids
        }

        var chains: [[String]] = []
        for index in kept.indices where !hasPredecessor[index] {
            chains.append(chain(startingAt: index))
        }
        for index in kept.indices where !visited[index] {
            chains.append(chain(startingAt: index))
        }
        return chains
    }

    // MARK: - Static Helpers

    static func displayName(for line: String, in graph: TransitGraph) -> String {
        if let name = graph.lines[line]?.displayName { return name }
        switch line {
        case "MRT-3", "MRT3":         return "MRT-3"
        case "LRT-1", "LRT1":         return "LRT-1"
        case "LRT-2", "LRT2":         return "LRT-2"
        case "EDSA_BUS", "EDSA_CAROUSEL": return "EDSA Carousel"
        case "COMMONWEALTH_BUS":      return "Commonwealth Bus"
        case "JEEPNEY_QUIAPO_CUBAO":  return "Jeepney Quiapo–Cubao"
        case "JEEPNEY_QUIAPO":        return "Jeepney Quiapo"
        case "JEEPNEY_NORTH":         return "Jeepney North"
        case "JEEPNEY_MAKATI":        return "Jeepney Makati"
        case "EJEEPNEY_BGC":          return "E-Jeepney BGC"
        case "TRICYCLE_MANILA":        return "Tricycle Manila"
        case "JEEPNEY_CARTIMAR_LRT":  return "Cartimar LRT Jeep"
        default:                       return line.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func lineWidth(for mode: String) -> CGFloat {
        switch mode {
        case "train":    return 6
        case "bus":      return 5
        case "jeepney":  return 4
        case "uv_express": return 4
        case "tricycle": return 3
        default:         return 3
        }
    }

    static func dotSize(for mode: String) -> CGFloat {
        switch mode {
        case "train":    return 13
        case "bus":      return 10
        case "jeepney":  return 9
        case "uv_express": return 9
        case "tricycle": return 8
        default:         return 8
        }
    }

    static func modeOrder(_ mode: String) -> Int {
        ["train": 0, "bus": 1, "jeepney": 2, "uv_express": 3, "tricycle": 4][mode] ?? 5
    }
}
