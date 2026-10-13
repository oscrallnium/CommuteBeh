//
//  AddStopView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/30/26.
//

import SwiftUI
import MapKit

// MARK: - Add Stop

/// Tap the route to place a stop. The tap snaps onto the nearest polyline vertex
/// (within `snapRadiusMeters`) because that's exactly where the backend splits the
/// segment — dropping a stop between two vertices leaves the pin visibly off the
/// junction the split produces. The panel then shows the polylines the insert will
/// create, vertex by vertex, before anything is written.
struct AddStopView: View {
    let lineStations: [Station]
    let lineEdges: [TransitEdge]
    /// The line's server-issued stop counter, or nil for a graph cached without one.
    let lastStopNumber: Int?
    let onSave: ([String: Any]) async throws -> Void

    /// A tap this far (metres) from a polyline vertex snaps onto it. Roughly the width
    /// of an intersection — close enough that the admin meant that vertex, far enough
    /// that a deliberate off-route placement still survives.
    static let snapRadiusMeters: CLLocationDistance = 25

    @Environment(\.dismiss) var dismiss
    @State var referenceStationId: String
    @State var selectedChainPrefix: String
    @State var position: String = "after"
    @State var name = ""
    @State var cameraPosition: MapCameraPosition
    @State var tappedCoordinate: CLLocationCoordinate2D?
    @State var snapEnabled = true
    @State var expandedPolylineID: String?
    @State var isSaving = false
    @State var errorMessage: String?
    /// Fetching road geometry for a head/tail insert's new segment.
    @State var isFetchingGeometry = false
    /// Set after a failed geometry fetch, so a second Save tap goes through anyway.
    @State var allowSaveWithoutGeometry = false
    /// Fetched road route per new edge, in creation order and oriented from → to. Drives
    /// both the preview and what gets posted, so the two can never disagree.
    @State private var roadGeometry: [[Coordinates]] = []
    /// Set by a tap that resolved to two opposite-direction segments — a road the route
    /// passes both ways. Save is blocked while this holds a value, and `directionChoiceRow`
    /// shows the two named options instead of the app guessing between them.
    @State var tapChoice: StopInsertionPreview.TapResolution?
    /// The direction of travel the admin last confirmed, by resolving a choice or by
    /// picking a Reference stop by hand. Passed to `StopInsertionPreview.resolveTap` as
    /// `preferredHeading` so a later tap — nudging the pin along the same carriageway —
    /// resolves to the same side instead of flipping to whichever segment is a hair closer.
    @State var resolvedHeading: CLLocationDirection?
    /// True when the most recent tap landed too far from every segment to resolve at all.
    @State var tapTooFarFromRoute = false
    /// Shows every stop in the stop-order list instead of only the stops near the new one.
    @State var showAllStops = false

    /// The line's independent stop chains, each in travel order.
    var chains: [(prefix: String, stations: [Station])] { StationChain.groups(of: lineStations) }

    /// The stops of the selected chain. Every insert is scoped to one chain, because the
    /// backend scopes by chain and a directional pair must not interleave.
    var orderedStations: [Station] {
        chains.first { $0.prefix == selectedChainPrefix }?.stations ?? []
    }

    /// Edges belonging to the selected chain — both endpoints inside it.
    var chainEdges: [TransitEdge] {
        let ids = Set(orderedStations.map(\.id))
        return lineEdges.filter { ids.contains($0.from) && ids.contains($0.to) }
    }

    private var linePolylines: [[Coordinates]] {
        chainEdges.map(\.polylineCoordinates).filter { !$0.isEmpty }
    }

    /// What a tap snaps against: the segment the pickers currently select, falling back to
    /// the whole line when that selection splits nothing (a head or tail insert). Snapping
    /// line-wide would, on a route that doubles back, pull a stop onto whichever of the two
    /// parallel traces happened to be marginally nearer — the wrong side of the road.
    private var snapCandidates: [[Coordinates]] {
        if let segment = StopInsertionPreview.segmentToSplit(
            referenceStationID: referenceStationId, position: position,
            stations: orderedStations, edges: chainEdges
        ), segment.coordinates.count >= 2 {
            return [segment.coordinates]
        }
        return linePolylines
    }

    /// The tap after snapping — nil until the admin has placed the stop.
    var snap: StopInsertionPreview.SnapResult? {
        guard let tappedCoordinate else { return nil }
        guard snapEnabled else {
            return StopInsertionPreview.SnapResult(
                coordinate: tappedCoordinate, tapped: tappedCoordinate, snappedDistanceMeters: nil
            )
        }
        return StopInsertionPreview.snap(
            tappedCoordinate, to: snapCandidates, within: Self.snapRadiusMeters
        )
    }

    var placedCoordinate: CLLocationCoordinate2D? { snap?.coordinate }

    /// The endpoints of every new edge that needs its own fetched road route, in creation
    /// order. Empty when the server can slice existing geometry instead.
    ///
    /// Orientation matters: the server stores what it is given, and a reversed polyline
    /// draws the route running backwards.
    ///
    /// - head/tail insert → one edge (new stop ↔ its only neighbour)
    /// - mid-chain insert into a segment with **no** drawable polyline → two edges, since
    ///   there is nothing to slice (this is the state a pre-fix head/tail insert left behind)
    /// - mid-chain insert into a real polyline → none; the server splits it
    func neededChords(for coordinate: CLLocationCoordinate2D)
    -> [(from: Coordinates, to: Coordinates)] {
        guard let slot = StopInsertionPreview.slot(
            referenceStationID: referenceStationId, position: position,
            ordered: orderedStations, edges: chainEdges
        ) else { return [] }
        let new = Coordinates(lat: coordinate.latitude, lng: coordinate.longitude)

        guard let previous = slot.previous else {
            return slot.next.map { [(new, $0.coordinates)] } ?? []      // new stop → old first stop
        }
        guard let next = slot.next else {
            return [(previous.coordinates, new)]                        // old last stop → new stop
        }

        let existing = StopInsertionPreview.edge(from: previous.id, to: next.id, in: chainEdges)?.coordinates ?? []
        guard existing.count < 2 else { return [] }         // real geometry — server slices it
        return [(previous.coordinates, new), (new, next.coordinates)]
    }

    var preview: StopInsertionPreview.Result? {
        guard let placedCoordinate else { return nil }
        return StopInsertionPreview.make(
            coordinate: placedCoordinate,
            referenceStationID: referenceStationId,
            position: position,
            stations: orderedStations,
            edges: chainEdges,
            roadGeometry: roadGeometry,
            lineStationIDs: lineStations.map(\.id),
            lastStopNumber: lastStopNumber
        )
    }

    /// The new polyline that joins the reference stop to the new stop: the first one for an
    /// "after" insert, and the last one for a "before" insert.
    var referencePolylineID: String? {
        let polylines = preview?.newPolylines ?? []
        return (position == "after" ? polylines.first : polylines.last)?.id
    }

    /// The segment the insert will split, shown until the stop is placed. Nil for a head or
    /// tail insert on an open chain, which splits nothing.
    var selectedSegment: [Coordinates]? {
        guard placedCoordinate == nil,
              let segment = StopInsertionPreview.segmentToSplit(
                referenceStationID: referenceStationId, position: position,
                stations: orderedStations, edges: chainEdges
              ),
              segment.coordinates.count >= 2 else { return nil }
        return segment.coordinates
    }

    /// The two candidate segments a pending choice points at, resolved to their own
    /// coordinates so the map can stroke both distinctly. Empty once the choice is
    /// resolved (see `directionChoiceSelection`) or was never ambiguous to begin with.
    var choiceHighlightSegments: [(id: String, coordinates: [Coordinates], isAlternative: Bool)] {
        guard let tapChoice, let alternative = tapChoice.alternative else { return [] }
        return [
            (tapChoice.chosen.station.id, false),
            (alternative.station.id, true)
        ].compactMap { stationID, isAlternative in
            guard let segment = StopInsertionPreview.segmentToSplit(
                referenceStationID: stationID, position: "after",
                stations: orderedStations, edges: chainEdges
            ) else { return nil }
            return (segment.id, segment.coordinates, isAlternative)
        }
    }

    /// Identifies what `roadGeometry` was fetched for, so a moved pin or a changed
    /// reference stop refetches instead of previewing a route to somewhere else.
    private var roadGeometryKey: String? {
        guard let placedCoordinate else { return nil }
        let chords = neededChords(for: placedCoordinate)
        guard !chords.isEmpty else { return nil }
        return chords.map {
            String(format: "%.6f,%.6f>%.6f,%.6f", $0.from.lat, $0.from.lng, $0.to.lat, $0.to.lng)
        }.joined(separator: "|")
    }

    /// Fetches the road route for a head/tail insert as soon as the stop is placed, so the
    /// preview shows the geometry that will actually be written rather than a chord.
    /// `DirectionsGateway` caches, so nudging a pin back to a previous spot costs nothing.
    func refreshRoadGeometry() async {
        guard let placedCoordinate else { return }
        let chords = neededChords(for: placedCoordinate)
        guard !chords.isEmpty else { return }

        let requestedKey = roadGeometryKey
        let transport = DirectionsTransport.snapType(for: chainEdges.first?.mkDirectionsTransportType)
        isFetchingGeometry = true
        defer { isFetchingGeometry = false }

        var fetched: [[Coordinates]] = []
        for chord in chords {
            // 2, not 3: a real MapKit route this short (the two ends can legitimately be
            // a few dozen metres apart) often
            // comes back as a plain two-point line, start to end, with no intermediate
            // shape points. 2 is the true floor a polyline needs to draw at all — anything
            // stricter was rejecting a real, successful route as if MapKit found nothing.
            guard let path = await DirectionsGateway.shared.path(
                from: chord.from, to: chord.to, transport: transport, urgency: .interactive
            ), path.coordinates.count >= 2 else { break }
            fetched.append(path.coordinates)
        }

        // The gateway isn't cancellation-aware, so a request started before the pin moved
        // still completes. Discard it rather than painting a route to the old placement.
        guard roadGeometryKey == requestedKey else { return }

        if fetched.count == chords.count {
            roadGeometry = fetched
            errorMessage = nil
            allowSaveWithoutGeometry = false
        } else {
            roadGeometry = []
            errorMessage = "Couldn't fetch a road route for the new segment yet — move the pin or try again in a moment."
        }
    }

    init(lineStations: [Station], lineEdges: [TransitEdge], lastStopNumber: Int?,
         onSave: @escaping ([String: Any]) async throws -> Void) {
        self.lineStations = lineStations
        self.lineEdges = lineEdges
        self.lastStopNumber = lastStopNumber
        self.onSave = onSave
        let chains = StationChain.groups(of: lineStations)
        let firstChain = chains.first
        _selectedChainPrefix = State(initialValue: firstChain?.prefix ?? "")
        _referenceStationId = State(initialValue: firstChain?.stations.first?.id ?? "")
        // Open framed on the chain being edited, not on one stop — placement is by tapping
        // the route, so it has to be on screen before the admin can do anything.
        _cameraPosition = State(
            initialValue: .region(Self.region(spanning: firstChain?.stations ?? lineStations))
        )
    }

    static func region(spanning stations: [Station]) -> MKCoordinateRegion {
        let coords = stations.map(\.coordinates)
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let lats = coords.map(\.lat), lngs = coords.map(\.lng)
        let minLat = lats.min() ?? first.lat, maxLat = lats.max() ?? first.lat
        let minLng = lngs.min() ?? first.lng, maxLng = lngs.max() ?? first.lng
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(maxLat - minLat, 0.004) * 1.4,
                longitudeDelta: max(maxLng - minLng, 0.004) * 1.4
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                MapReader { proxy in
                    map
                        .onTapGesture { point in
                            guard let coordinate = proxy.convert(point, from: .local) else { return }
                            place(coordinate)
                        }
                }
                .ignoresSafeArea()

                VStack(spacing: 8) {
                    if tappedCoordinate == nil {
                        instructionPill
                    }
                    formPanel
                }
            }
            .navigationTitle("Add Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Keyed on the chord's endpoints: re-runs when the pin moves or the reference
            // stop/position changes, and cancels the in-flight fetch when it does.
            .task(id: roadGeometryKey) {
                roadGeometry = []
                guard roadGeometryKey != nil else { return }
                await refreshRoadGeometry()
            }
        }
    }
}
