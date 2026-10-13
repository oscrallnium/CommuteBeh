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
/// - The chain is ordered by `StationChain.ordered`, and the 1-based insertion
///   slot is `refIndex + 2` for "after", `refIndex + 1` for "before".
/// - The new ids follow the backend convention: `<chain>_S<n>` for the stop and
///   `<from>__<to>` for each edge. No existing id is renamed.
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

    /// A chain is a closed loop when an edge runs from its last stop to its first stop.
    static func isClosedLoop(_ ordered: [Station], edges: [TransitEdge]) -> Bool {
        guard ordered.count >= 2, let first = ordered.first, let last = ordered.last else { return false }
        return edge(from: last.id, to: first.id, in: edges)?.edge.from == last.id
    }

    /// Where an insert lands: the 1-based slot `p` and the stops on each side. `previous` is
    /// nil for a head insert and `next` is nil for a tail insert. A closed loop has neither,
    /// because the slot before the first stop is the slot after the last, on the closing edge.
    struct Slot {
        let p: Int
        let previous: Station?
        let next: Station?
    }

    static func slot(
        referenceStationID: StationID,
        position: String,
        ordered: [Station],
        edges: [TransitEdge]
    ) -> Slot? {
        guard let refIndex = ordered.firstIndex(where: { $0.id == referenceStationID }) else { return nil }
        let n = ordered.count
        var p = position == "after" ? refIndex + 2 : refIndex + 1
        guard isClosedLoop(ordered, edges: edges) else {
            return Slot(p: p, previous: p > 1 ? ordered[p - 2] : nil, next: p <= n ? ordered[p - 1] : nil)
        }
        if p == 1 { p = n + 1 }
        return Slot(p: p, previous: ordered[p - 2], next: p <= n ? ordered[p - 1] : ordered[0])
    }

    // MARK: - Preview

    /// One polyline the insert will create, ready to draw and to list coordinate by
    /// coordinate.
    struct NewPolyline: Identifiable {
        let id: String              // e.g. "JEEP_X_S2__JEEP_X_S3" — the edge id the server will write
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
        roadGeometry: [[Coordinates]] = [],
        lineStationIDs: [String],
        lastStopNumber: Int?
    ) -> Result? {
        let ordered = StationChain.ordered(stations)
        guard let slot = slot(referenceStationID: referenceStationID, position: position,
                              ordered: ordered, edges: edges),
              let prefix = StationChain.prefix(of: referenceStationID) else { return nil }

        let p = slot.p
        let newStationID = StationChain.nextStopID(chain: prefix, lineStationIDs: lineStationIDs,
                                                  lastStopNumber: lastStopNumber)

        // Mid-chain: the segment between the two stops the new one lands between gets
        // split in two. Head and tail inserts on an open chain have no segment to split.
        guard let previous = slot.previous, let next = slot.next else {
            let isHead = slot.previous == nil
            guard let neighbour = isHead ? slot.next : slot.previous else { return nil }
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
                    id: isHead ? "\(newStationID)__\(neighbour.id)" : "\(neighbour.id)__\(newStationID)",
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

        guard let match = edge(from: previous.id, to: next.id, in: edges) else { return nil }
        let poly = match.coordinates
        // Splitting a segment that has no drawable polyline (fewer than two points) can't
        // slice anything — both halves need their own fetched road route, exactly like a
        // head/tail insert.
        guard poly.count >= 2 else {
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
                    NewPolyline(id: "\(previous.id)__\(newStationID)", fromName: previous.name,
                                toName: "New stop", coordinates: firstHalf, isFetched: true),
                    NewPolyline(id: "\(newStationID)__\(next.id)", fromName: "New stop",
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
                    id: "\(previous.id)__\(newStationID)",
                    fromName: previous.name,
                    toName: "New stop",
                    coordinates: firstHalf,
                    isFetched: false
                ),
                NewPolyline(
                    id: "\(newStationID)__\(next.id)",
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
}
