//
//  AddStopView+Map.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import SwiftUI
import MapKit

// The map: the chain, the segment the insert replaces, the new polylines, and their vertices.
// These members are internal only because the stored properties they read sit in AddStopView.swift.

extension AddStopView {

    // MARK: - Map

    var map: some View {
        Map(position: $cameraPosition) {
            // Existing geometry, dimmed — the segment about to be replaced is drawn
            // separately below so it reads as "this is what's going away".
            ForEach(chainEdges) { edge in
                if edge.polylineCoordinates.count >= 2, edge.id != preview?.replacedEdge?.id {
                    MapPolyline(coordinates: edge.polylineCoordinates.map(\.clCoordinate))
                        .stroke(Color.slate.opacity(0.55), lineWidth: 3)
                }
            }

            if let replaced = preview?.replacedEdge, replaced.coordinates.count >= 2 {
                MapPolyline(coordinates: replaced.coordinates.map(\.clCoordinate))
                    .stroke(Color.vermilion.opacity(0.35), style: StrokeStyle(lineWidth: 7, dash: [2, 6]))
            }

            // Before a stop is placed: the segment between the reference stop and its
            // neighbour on the chosen side, where the new stop will go.
            if let selectedSegment {
                MapPolyline(coordinates: selectedSegment.map(\.clCoordinate))
                    .stroke(Color.onyx, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }

            // The two candidate segments of a pending direction choice, so the admin can
            // see which physical road each named option actually refers to.
            ForEach(choiceHighlightSegments, id: \.id) { segment in
                if segment.coordinates.count >= 2 {
                    MapPolyline(coordinates: segment.coordinates.map(\.clCoordinate))
                        .stroke(
                            segment.isAlternative ? Color.ember : Color.onyx,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round,
                                               dash: segment.isAlternative ? [8, 5] : [])
                        )
                }
            }

            // The polylines this insert creates.
            ForEach(Array((preview?.newPolylines ?? []).enumerated()), id: \.element.id) { index, poly in
                if poly.coordinates.count >= 2 {
                    MapPolyline(coordinates: poly.coordinates.map(\.clCoordinate))
                        // Solid, always: every polyline drawn here is real geometry —
                        // sliced from the existing segment or fetched from MKDirections.
                        // The dashed style used to mean "straight chord", which is no
                        // longer a thing this view can produce.
                        // The polyline that joins the reference stop to the new stop is drawn
                        // wider, so the admin sees which connection the picker chose.
                        .stroke(
                            (index == 0 ? Color.slate : Color.ember)
                                .opacity(poly.id == referencePolylineID ? 1 : 0.6),
                            style: StrokeStyle(lineWidth: poly.id == referencePolylineID ? 8 : 4,
                                               lineCap: .round)
                        )
                }
            }

            // Every vertex of the new polylines — these are the lat/lngs being written.
            // Screen-space dots rather than MapCircle, so they stay legible at the zoom
            // levels this view is actually used at instead of collapsing to sub-pixels.
            ForEach(newVertexMarkers) { marker in
                Annotation("", coordinate: marker.coordinate) {
                    Circle()
                        .fill(marker.color)
                        .frame(width: marker.isJunction ? 12 : 6,
                               height: marker.isJunction ? 12 : 6)
                        .overlay(Circle().stroke(.white, lineWidth: marker.isJunction ? 2 : 1))
                }
                .annotationTitles(.hidden)
            }

            ForEach(orderedStations) { station in
                let isReference = station.id == referenceStationId
                Annotation(station.name, coordinate: station.coordinates.clCoordinate) {
                    Circle()
                        .fill(isReference ? Color.onyx : Color.canvas)
                        .frame(width: isReference ? 15 : 11, height: isReference ? 15 : 11)
                        .overlay(Circle().stroke(isReference ? Color.canvas : Color.slate, lineWidth: 3))
                }
                .annotationTitles(isReference ? .visible : .hidden)
            }

            // Where the tap landed before snapping, so the snap itself is visible.
            if let snap, snap.didSnap {
                Annotation("", coordinate: snap.tapped) {
                    Circle()
                        .strokeBorder(Color.onyx.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 16, height: 16)
                }
                MapPolyline(coordinates: [snap.tapped, snap.coordinate])
                    .stroke(Color.onyx.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }

            if let placedCoordinate {
                Annotation(name.isEmpty ? "New stop" : name, coordinate: placedCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.onyx)
                        .background(Circle().fill(Color.canvas).frame(width: 16, height: 16))
                }
            }
        }
    }

    /// Slate for the vertices of the first new polyline, ember for the second — matching
    /// the strokes — with the shared split vertex drawn once, larger and in onyx, on top.
    private struct VertexMarker: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
        var isJunction = false
    }

    /// Dense recorded polylines can carry hundreds of points; past this many the dots
    /// merge into a solid band anyway, so thin them evenly rather than pay for
    /// annotations nobody can distinguish.
    private static let maxVertexMarkers = 250

    private var newVertexMarkers: [VertexMarker] {
        guard let preview else { return [] }
        let all = preview.newPolylines.enumerated().flatMap { index, poly in
            poly.coordinates.enumerated().map { i, point in
                VertexMarker(
                    id: "\(poly.id)-\(i)",
                    coordinate: point.clCoordinate,
                    color: index == 0 ? Color.slate : Color.ember
                )
            }
        }
        let stride = max(1, all.count / Self.maxVertexMarkers)
        var markers = stride == 1 ? all : all.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        if let splitVertex = preview.splitVertex {
            markers.append(VertexMarker(
                id: "split", coordinate: splitVertex.clCoordinate, color: Color.onyx, isJunction: true
            ))
        }
        return markers
    }
}

private extension Coordinates {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
