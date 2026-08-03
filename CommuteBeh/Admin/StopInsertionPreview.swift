//
//  StopInsertionPreview.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/27/26.
//

import Foundation
import CoreLocation

/// Pure geometry behind "Add Stop": where a tapped coordinate snaps to, and which
/// polylines inserting a stop there would produce.
///
/// This mirrors `GraphService#insert_stop` on the backend rather than inventing its
/// own rules — the point of the preview is to show what the server will actually
/// write, so any divergence here would be a lie on screen:
///
/// - The chain is ordered by the `<prefix>_STOP<n>` suffix, and the 1-based insertion
///   slot is `refIndex + 2` for "after", `refIndex + 1` for "before".
/// - A mid-chain insert splits the existing segment's polyline at the **vertex nearest
///   the new stop** (`split_point_index`), and both halves keep that shared vertex —
///   first half is `poly[0...i]`, second is `poly[i...]`.
/// - A head/tail insert has no geometry to slice, and neither does a mid-chain insert into
///   a segment whose polyline is empty. In both cases `AddStopView` fetches the road route
///   for each new edge and posts it as `newEdgePolylines`; the server stores it and flags
///   `is_road_snapped: true`. (Head/tail inserts used to be written with an empty polyline
///   "for Explore to snap later" — Explore only ever snapped into its own in-memory cache
///   and never wrote back, so those edges stayed empty forever, e.g. UPLB_KANAN_SEG8.)
///
/// **No straight chord is ever drawn or written.** Until the fetched geometry arrives there
/// is nothing honest to show, so nothing is drawn — a chord would be a picture of a road
/// that doesn't exist, and the admin would be approving it.
///
/// Because the server splits at a polyline vertex but stores the stop at the exact
/// lat/lng it was given, a stop dropped off-vertex leaves a visible gap between the
/// pin and the polyline junction. Snapping (`snap(_:to:within:)`) closes that gap by
/// moving the stop onto the vertex the split would use anyway.
enum StopInsertionPreview {

    // MARK: - Snapping

    struct SnapResult {
        /// The coordinate to actually save — the snapped vertex, or the raw tap if
        /// nothing was close enough.
        let coordinate: CLLocationCoordinate2D
        /// The raw tapped coordinate, kept so the UI can show what moved and by how far.
        let tapped: CLLocationCoordinate2D
        /// Distance in metres from the tap to the vertex it snapped onto — nil if unsnapped.
        let snappedDistanceMeters: CLLocationDistance?

        var didSnap: Bool { snappedDistanceMeters != nil }
    }

    /// Snaps `tapped` onto the nearest vertex of `polylines` when one lies within
    /// `radius` metres. Vertex-only (not projected onto the segment between two
    /// vertices) on purpose: the server's split index is an *index into the existing
    /// point array*, so only an existing vertex can be a lossless junction.
    static func snap(
        _ tapped: CLLocationCoordinate2D,
        to polylines: [[Coordinates]],
        within radius: CLLocationDistance
    ) -> SnapResult {
        let tapLocation = CLLocation(latitude: tapped.latitude, longitude: tapped.longitude)
        var best: (coord: Coordinates, distance: CLLocationDistance)?

        for polyline in polylines {
            for point in polyline {
                let distance = tapLocation.distance(
                    from: CLLocation(latitude: point.lat, longitude: point.lng)
                )
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (point, distance)
                }
            }
        }

        guard let best, best.distance <= radius else {
            return SnapResult(coordinate: tapped, tapped: tapped, snappedDistanceMeters: nil)
        }
        return SnapResult(
            coordinate: CLLocationCoordinate2D(latitude: best.coord.lat, longitude: best.coord.lng),
            tapped: tapped,
            snappedDistanceMeters: best.distance
        )
    }

    // MARK: - Chain ordering

    /// Chain position encoded in an auto-generated station id (`..._STOP7` → 7).
    /// Nil for hand-authored ids (train stations), which the backend refuses to
    /// insert into anyway.
    static func stopNumber(_ id: String) -> Int? {
        guard let range = id.range(of: #"_STOP(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(id[range].replacingOccurrences(of: "_STOP", with: ""))
    }

    /// Stations in travel order. Ids without a `_STOP<n>` suffix sort last, keeping
    /// their relative order, so a mixed line still renders something sensible.
    static func orderedChain(_ stations: [Station]) -> [Station] {
        stations.enumerated()
            .sorted { a, b in
                let na = stopNumber(a.element.id) ?? .max
                let nb = stopNumber(b.element.id) ?? .max
                return na == nb ? a.offset < b.offset : na < nb
            }
            .map(\.element)
    }

    /// The edge connecting two consecutive stops, with its polyline oriented `from → to`.
    /// Bidirectional lines store one edge per pair, so a reversed match is reversed here
    /// rather than treated as missing.
    static func edge(
        from: StationID,
        to: StationID,
        in edges: [TransitEdge]
    ) -> (edge: TransitEdge, coordinates: [Coordinates])? {
        if let match = edges.first(where: { $0.from == from && $0.to == to }) {
            return (match, match.polylineCoordinates)
        }
        if let reversed = edges.first(where: { $0.from == to && $0.to == from }) {
            return (reversed, reversed.polylineCoordinates.reversed())
        }
        return nil
    }

    // MARK: - Preview

    /// One polyline the insert will create, ready to draw and to list coordinate by
    /// coordinate.
    struct NewPolyline: Identifiable {
        let id: String              // e.g. "JEEP_X_SEG3" — the edge id the server will write
        let fromName: String
        let toName: String
        let coordinates: [Coordinates]
        /// True when this geometry was fetched from MKDirections (and must therefore be
        /// posted to the server), false when it was sliced from the existing segment's own
        /// recorded polyline (which the server re-derives itself and must not be sent).
        let isFetched: Bool

        var lengthKm: Double {
            guard coordinates.count >= 2 else { return 0 }
            return zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
                total + CLLocation(latitude: pair.0.lat, longitude: pair.0.lng)
                    .distance(from: CLLocation(latitude: pair.1.lat, longitude: pair.1.lng)) / 1000
            }
        }
    }

    struct Result {
        /// 1-based slot the new stop takes in the chain (the server's `p`).
        let insertionSlot: Int
        /// The station id the server will assign.
        let newStationID: String
        /// The two halves of a split segment, or the single new chord for head/tail.
        let newPolylines: [NewPolyline]
        /// The existing segment being replaced, oriented from → to. Nil for head/tail.
        let replacedEdge: (id: String, coordinates: [Coordinates])?
        /// Index into `replacedEdge.coordinates` where the split lands — the shared
        /// junction vertex both halves keep.
        let splitVertexIndex: Int?
        /// Set when the stop sits far enough off the segment that the split vertex and
        /// the pin won't visually coincide.
        let warning: String?

        var splitVertex: Coordinates? {
            guard let replacedEdge, let splitVertexIndex,
                  replacedEdge.coordinates.indices.contains(splitVertexIndex) else { return nil }
            return replacedEdge.coordinates[splitVertexIndex]
        }
    }

    /// Distance beyond which the pin and the split vertex are far enough apart to be
    /// worth calling out — the same order of magnitude as the default snap radius.
    private static let offSegmentWarningMeters: CLLocationDistance = 30

    /// `roadGeometry` holds the fetched road route for each new edge, in the order the
    /// edges are created and already oriented from → to (see `AddStopView.neededChords`).
    /// One entry for a head/tail insert, two when splitting a segment that has no polyline
    /// of its own, none when there is real geometry to slice. Without it those inserts have
    /// nothing honest to draw, and this preview will not substitute a straight chord — on
    /// screen or in what it reports will be written.
    static func make(
        coordinate: CLLocationCoordinate2D,
        referenceStationID: StationID,
        position: String,           // "before" | "after"
        stations: [Station],
        edges: [TransitEdge],
        roadGeometry: [[Coordinates]] = []
    ) -> Result? {
        let ordered = orderedChain(stations)
        guard let refIndex = ordered.firstIndex(where: { $0.id == referenceStationID }),
              let prefix = sequencePrefix(referenceStationID) else { return nil }

        let n = ordered.count
        let p = position == "after" ? refIndex + 2 : refIndex + 1
        let newStationID = "\(prefix)_STOP\(p)"

        // Mid-chain: the segment between the two stops the new one lands between gets
        // split in two. Head (p == 1) and tail (p == n + 1) have no segment to split.
        guard p > 1, p <= n else {
            let neighbour = p == 1 ? ordered.first : ordered.last
            guard let neighbour else { return nil }
            let isHead = p == 1
            let newStop = Coordinates(lat: coordinate.latitude, lng: coordinate.longitude)

            // No existing segment to slice, so the road route is the only real geometry
            // available. Until it arrives, draw nothing: a straight chord here would be a
            // picture of a road that doesn't exist, and the admin would be approving it.
            guard let road = roadGeometry.first, road.count >= 2 else {
                return Result(
                    insertionSlot: p,
                    newStationID: newStationID,
                    newPolylines: [],
                    replacedEdge: nil,
                    splitVertexIndex: nil,
                    warning: "Fetching the road route between \(neighbour.name) and the new stop — nothing is drawn until it arrives."
                )
            }

            // Pin the ends to the two stops, matching what the server stores: MKDirections
            // snaps its endpoints to the nearest road, and the pins are drawn from the stop
            // coordinates, so any drift reads as a gap between pin and line.
            var pinned = road
            pinned[0] = isHead ? newStop : neighbour.coordinates
            pinned[pinned.count - 1] = isHead ? neighbour.coordinates : newStop

            return Result(
                insertionSlot: p,
                newStationID: newStationID,
                newPolylines: [NewPolyline(
                    id: isHead ? "\(prefix)_SEG1" : "\(prefix)_SEG\(n)",
                    fromName: isHead ? "New stop" : neighbour.name,
                    toName: isHead ? neighbour.name : "New stop",
                    coordinates: pinned,
                    isFetched: true
                )],
                replacedEdge: nil,
                splitVertexIndex: nil,
                warning: nil
            )
        }

        let previous = ordered[p - 2]
        let next = ordered[p - 1]
        guard let match = edge(from: previous.id, to: next.id, in: edges) else { return nil }
        let poly = match.coordinates
        // Splitting a segment that has no polyline of its own (e.g. a head/tail edge saved
        // before this flow fetched geometry) can't slice anything — both halves need their
        // own fetched road route, exactly like a head/tail insert.
        guard !poly.isEmpty else {
            let newStop = Coordinates(lat: coordinate.latitude, lng: coordinate.longitude)
            guard roadGeometry.count == 2,
                  roadGeometry[0].count >= 2, roadGeometry[1].count >= 2 else {
                return Result(
                    insertionSlot: p,
                    newStationID: newStationID,
                    newPolylines: [],
                    replacedEdge: (match.edge.id, poly),
                    splitVertexIndex: nil,
                    warning: "\(previous.name) → \(next.name) has no recorded polyline to split — fetching a road route for both halves."
                )
            }

            var firstHalf = roadGeometry[0]
            firstHalf[0] = previous.coordinates
            firstHalf[firstHalf.count - 1] = newStop
            var secondHalf = roadGeometry[1]
            secondHalf[0] = newStop
            secondHalf[secondHalf.count - 1] = next.coordinates

            return Result(
                insertionSlot: p,
                newStationID: newStationID,
                newPolylines: [
                    NewPolyline(id: "\(prefix)_SEG\(p - 1)", fromName: previous.name,
                                toName: "New stop", coordinates: firstHalf, isFetched: true),
                    NewPolyline(id: "\(prefix)_SEG\(p)", fromName: "New stop",
                                toName: next.name, coordinates: secondHalf, isFetched: true)
                ],
                replacedEdge: (match.edge.id, poly),
                splitVertexIndex: nil,
                warning: nil
            )
        }

        let splitIndex = nearestVertexIndex(to: coordinate, in: poly)
        let firstHalf = Array(poly[0...splitIndex])
        let secondHalf = Array(poly[splitIndex...])

        let splitVertex = poly[splitIndex]
        let gap = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: splitVertex.lat, longitude: splitVertex.lng))

        return Result(
            insertionSlot: p,
            newStationID: newStationID,
            newPolylines: [
                NewPolyline(
                    id: "\(prefix)_SEG\(p - 1)",
                    fromName: previous.name,
                    toName: "New stop",
                    coordinates: firstHalf,
                    isFetched: false
                ),
                NewPolyline(
                    id: "\(prefix)_SEG\(p)",
                    fromName: "New stop",
                    toName: next.name,
                    coordinates: secondHalf,
                    isFetched: false
                )
            ],
            replacedEdge: (match.edge.id, poly),
            splitVertexIndex: splitIndex,
            warning: gap > offSegmentWarningMeters
                ? String(format: "Stop sits %.0f m off this segment — the split point won't line up with the pin.", gap)
                : nil
        )
    }

    // MARK: - Segment lookup

    /// The consecutive stop pair whose polyline passes closest to `coordinate`, so a tap
    /// on the map can pre-select the segment it lands on instead of previewing a split of
    /// whatever pair the pickers happened to be left on. Returns the *earlier* stop of the
    /// pair — the reference stop for a `position: "after"` insert.
    static func nearestSegmentStart(
        to coordinate: CLLocationCoordinate2D,
        stations: [Station],
        edges: [TransitEdge]
    ) -> (station: Station, distanceMeters: CLLocationDistance)? {
        nearestSegmentStarts(to: coordinate, stations: stations, edges: edges).first
    }

    /// Every segment ranked by how close its polyline passes to `coordinate`, nearest
    /// first. The runner-up matters: on a route that doubles back, the outbound and
    /// return segments run alongside each other, and picking the closer of two
    /// near-identical distances is a coin toss the caller should decline to make.
    static func nearestSegmentStarts(
        to coordinate: CLLocationCoordinate2D,
        stations: [Station],
        edges: [TransitEdge]
    ) -> [(station: Station, distanceMeters: CLLocationDistance)] {
        let ordered = orderedChain(stations)
        guard ordered.count >= 2 else { return [] }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return ordered.dropLast().enumerated().compactMap { i, station in
            guard let match = edge(from: station.id, to: ordered[i + 1].id, in: edges) else { return nil }
            let nearest = match.coordinates
                .map { target.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) }
                .min()
            guard let nearest else { return nil }
            return (station, nearest)
        }
        .sorted { $0.1 < $1.1 }
    }

    /// The segment an insert at `position` relative to `referenceStationID` would split,
    /// oriented from → to. Depends only on the chain and the picker selection, not on
    /// where the stop lands, so it can be resolved before a coordinate is chosen — which
    /// is what lets a tap snap to the selected segment rather than to the whole line.
    /// Nil for a head or tail insert, which splits nothing.
    static func segmentToSplit(
        referenceStationID: StationID,
        position: String,
        stations: [Station],
        edges: [TransitEdge]
    ) -> (id: String, coordinates: [Coordinates])? {
        let ordered = orderedChain(stations)
        guard let refIndex = ordered.firstIndex(where: { $0.id == referenceStationID }) else { return nil }
        let p = position == "after" ? refIndex + 2 : refIndex + 1
        guard p > 1, p <= ordered.count else { return nil }
        guard let match = edge(from: ordered[p - 2].id, to: ordered[p - 1].id, in: edges) else { return nil }
        return (match.edge.id, match.coordinates)
    }

    // MARK: - Helpers

    /// Mirrors the backend's `split_point_index`: nearest *vertex* by squared lat/lng
    /// distance, not a projection onto the segment between vertices.
    static func nearestVertexIndex(to coordinate: CLLocationCoordinate2D, in polyline: [Coordinates]) -> Int {
        var bestIndex = 0
        var bestDistanceSq = Double.greatestFiniteMagnitude
        for (i, point) in polyline.enumerated() {
            let dLat = point.lat - coordinate.latitude
            let dLng = point.lng - coordinate.longitude
            let distanceSq = dLat * dLat + dLng * dLng
            if distanceSq < bestDistanceSq {
                bestDistanceSq = distanceSq
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// `"JEEP_QUIAPO_NB_STOP4"` → `"JEEP_QUIAPO_NB"`. Nil for hand-authored ids.
    static func sequencePrefix(_ stationID: StationID) -> String? {
        guard let range = stationID.range(of: #"_STOP\d+$"#, options: .regularExpression) else { return nil }
        return String(stationID[..<range.lowerBound])
    }
}
