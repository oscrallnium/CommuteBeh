//
//  AdminEdgesView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

//
//  AdminEdgesView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI
import MapKit

// MARK: - ViewModel

@Observable
@MainActor
final class AdminEdgesViewModel {

    struct LineGroup: Identifiable {
        let id: String
        var edges: [TransitEdge]
    }

    var lineGroups: [LineGroup] = []
    var stationIndex: [StationID: Station] = [:]
    var errorMessage: String?
    var isBulkUpdating = false
    var bulkUpdateError: String?

    func load() {
        switch GraphLoader.load() {
        case .success(let graph):
            stationIndex = Dictionary(uniqueKeysWithValues: graph.stations.map { ($0.id, $0) })
            var dict: [String: [TransitEdge]] = [:]
            for edge in graph.edges {
                dict[edge.line, default: []].append(edge)
            }
            lineGroups = dict
                .map { LineGroup(id: $0.key, edges: $0.value.sorted { $0.from < $1.from }) }
                .sorted { $0.id < $1.id }
        case .failure:
            errorMessage = "Failed to load transit data."
        }
    }

    func stationName(for id: StationID) -> String {
        stationIndex[id]?.name ?? id
    }

    func updateEdge(
        _ edge: TransitEdge,
        polylineCoordinates: [Coordinates]? = nil,
        bidirectional: Bool? = nil
    ) async throws {
        let updated = try await AdminService.shared.updateEdge(
            id: edge.id, polylineCoordinates: polylineCoordinates, bidirectional: bidirectional
        )
        apply(updated)
    }

    /// Sets one-wayness across a whole line in one action.
    ///
    /// Repairing by hand isn't realistic: an insert done before the backend inherited
    /// directionality left two two-way segments buried in an otherwise one-way chain, and
    /// a long route has dozens of edges to check. Continues past individual failures so a
    /// single rejected edge doesn't abandon the rest half-converted, and reports what
    /// didn't take.
    func setBidirectionalForLine(_ lineId: String, to value: Bool) async {
        isBulkUpdating = true
        bulkUpdateError = nil
        let targets = (lineGroups.first { $0.id == lineId }?.edges ?? [])
            .filter { $0.bidirectional != value }

        var failed: [String] = []
        for edge in targets {
            do {
                let updated = try await AdminService.shared.updateEdge(
                    id: edge.id, bidirectional: value
                )
                apply(updated)
            } catch {
                failed.append(edge.id)
            }
        }
        if !failed.isEmpty {
            bulkUpdateError = failed.count == targets.count
                ? "Couldn't update any segment."
                : "Updated \(targets.count - failed.count) of \(targets.count); \(failed.count) failed."
        }
        isBulkUpdating = false
    }

    private func apply(_ updated: TransitEdge) {
        for i in lineGroups.indices {
            guard let j = lineGroups[i].edges.firstIndex(where: { $0.id == updated.id }) else { continue }
            lineGroups[i].edges[j] = updated
            persistToLocalGraph(updated)
            break
        }
    }

    // Takes the server's full response edge rather than reconstructing from the old
    // cached one — the server recomputes distance_km and (as of this fix) sets
    // is_road_snapped: true for a hand-edited polyline; reusing stale `old` values
    // for those would silently undo half the point of trusting this edit.
    private func persistToLocalGraph(_ updatedEdge: TransitEdge) {
        guard case .success(let graph) = GraphLoader.load(),
              let idx = graph.edges.firstIndex(where: { $0.id == updatedEdge.id }),
              let url = GraphLoader.documentsURL() else { return }

        var edges = graph.edges
        edges[idx] = updatedEdge
        let newGraph = TransitGraph(
            version: graph.version, stations: graph.stations, edges: edges,
            peakHourMultipliers: graph.peakHourMultipliers,
            transportModes: graph.transportModes, paymentMethods: graph.paymentMethods,
            lines: graph.lines, enforceOperatingHours: graph.enforceOperatingHours
        )
        guard let data = try? JSONEncoder().encode(newGraph) else { return }
        try? data.write(to: url)
        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }
}

// MARK: - Root: list of lines

struct AdminEdgesView: View {
    @State private var vm = AdminEdgesViewModel()

    var body: some View {
        Group {
            if let error = vm.errorMessage {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if vm.lineGroups.isEmpty {
                ProgressView("Loading edges…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.lineGroups) { group in
                    NavigationLink(destination: EdgeListView(group: group, vm: vm)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.id).font(.headline)
                            Text("\(group.edges.count) edges")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Edit Polylines")
        .onAppear { vm.load() }
    }
}

// MARK: - Edge list for a single line

private struct EdgeListView: View {
    let group: AdminEdgesViewModel.LineGroup
    let vm: AdminEdgesViewModel
    @State private var selectedEdge: TransitEdge?

    private var currentEdges: [TransitEdge] {
        vm.lineGroups.first(where: { $0.id == group.id })?.edges ?? group.edges
    }

    /// A line whose segments disagree is the signature of a stop inserted before the
    /// backend inherited directionality — the two halves of the split segment came back
    /// two-way inside an otherwise one-way chain.
    private var hasMixedDirectionality: Bool {
        let values = Set(currentEdges.map(\.bidirectional))
        return values.count > 1
    }

    var body: some View {
        List {
            if hasMixedDirectionality {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Some segments are one-way and others two-way. A two-way segment inside a one-way route lets the app route riders backwards along it.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Button("Make all one-way") {
                                Task { await vm.setBidirectionalForLine(group.id, to: false) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Make all two-way") {
                                Task { await vm.setBidirectionalForLine(group.id, to: true) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .disabled(vm.isBulkUpdating)
                    }
                }
            }
            if let error = vm.bulkUpdateError {
                Section { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section {
                ForEach(currentEdges) { edge in
                    EdgeRow(
                        edge: edge,
                        fromName: vm.stationName(for: edge.from),
                        toName: vm.stationName(for: edge.to)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEdge = edge }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.large)
        .disabled(vm.isBulkUpdating)
        .overlay {
            if vm.isBulkUpdating {
                ProgressView("Updating segments…")
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .fullScreenCover(item: $selectedEdge) { edge in
            EditEdgePolylineView(
                edge: edge,
                fromName: vm.stationName(for: edge.from),
                toName: vm.stationName(for: edge.to),
                fromCoordinate: vm.stationIndex[edge.from]?.coordinates,
                toCoordinate: vm.stationIndex[edge.to]?.coordinates
            ) { newCoords, isOneWay in
                try await vm.updateEdge(edge,
                                        polylineCoordinates: newCoords,
                                        bidirectional: !isOneWay)
            }
        }
    }
}

// MARK: - Row

private struct EdgeRow: View {
    let edge: TransitEdge
    let fromName: String
    let toName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(fromName) → \(toName)")
                    .font(.headline)
                    .lineLimit(1)
                if let dir = edge.direction {
                    Text(dir.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 6) {
                // One-wayness decides whether the engine synthesises a reverse edge, so
                // it belongs on the row: it's the difference between a rider being sent
                // to the correct side of the road and the opposite one.
                Text(edge.bidirectional ? "Two-way" : "One-way")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(edge.bidirectional ? Color.orange.opacity(0.14) : Color.green.opacity(0.14))
                    .foregroundStyle(edge.bidirectional ? .orange : .green)
                    .clipShape(Capsule())
                Text("\(edge.polylineCoordinates.count) waypoints")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Polyline editor

private struct EditEdgePolylineView: View {
    let edge: TransitEdge
    let fromName: String
    let toName: String
    /// The edge's endpoints, needed to fetch a road route for an edge that has no usable
    /// geometry to edit — nil only if the station is missing from the local graph.
    let fromCoordinate: Coordinates?
    let toCoordinate: Coordinates?
    let onSave: ([Coordinates], Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waypoints: [Coordinates]
    @State private var isOneWay: Bool
    @State private var selectedIndex: Int
    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var cameraDistance: CLLocationDistance = 500
    @State private var isSaving = false
    @State private var isSnapping = false
    @State private var errorMessage: String?

    init(edge: TransitEdge, fromName: String, toName: String,
         fromCoordinate: Coordinates?, toCoordinate: Coordinates?,
         onSave: @escaping ([Coordinates], Bool) async throws -> Void) {
        self.edge = edge
        self.fromName = fromName
        self.toName = toName
        self.fromCoordinate = fromCoordinate
        self.toCoordinate = toCoordinate
        self.onSave = onSave
        let coords = edge.polylineCoordinates
        _waypoints = State(initialValue: coords)
        _isOneWay = State(initialValue: !edge.bidirectional)
        _selectedIndex = State(initialValue: 0)
        let anchor = coords.first.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        } ?? CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194)
        _cameraPosition = State(initialValue: .camera(
            MapCamera(centerCoordinate: anchor, distance: 500, heading: 0, pitch: 0)
        ))
        _centerCoordinate = State(initialValue: anchor)
    }

    var body: some View {
        ZStack {
            // Map layer
            Map(position: $cameraPosition) {
                if waypoints.count >= 2 {
                    MapPolyline(coordinates: waypoints.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    })
                    .stroke(.blue.opacity(0.7), lineWidth: 3)
                }
                ForEach(Array(waypoints.enumerated()), id: \.offset) { i, wp in
                    let coord2D = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lng)
                    let isSelected = i == selectedIndex
                    Annotation("", coordinate: coord2D) {
                        ZStack {
                            Circle()
                                .fill(isSelected ? .orange : .blue)
                                .frame(width: isSelected ? 30 : 22, height: isSelected ? 30 : 22)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(color: .black.opacity(0.3), radius: 3)
                            Text("\(i + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                        .onTapGesture {
                            selectedIndex = i
                            withAnimation {
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: coord2D,
                                    distance: cameraDistance,
                                    heading: 0, pitch: 0
                                ))
                            }
                        }
                    }
                }
            }
            .onMapCameraChange(frequency: .continuous) { ctx in
                centerCoordinate = ctx.camera.centerCoordinate
                cameraDistance = ctx.camera.distance
            }
            .ignoresSafeArea()

            // Crosshair
            VStack(spacing: 0) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                Rectangle()
                    .fill(.red)
                    .frame(width: 1.5, height: 8)
            }

            // Chrome overlay
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(fromName) → \(toName)")
                            .font(.headline)
                            .lineLimit(1)
                        Text(edge.line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 56)

                Spacer()

                // Bottom control panel
                VStack(spacing: 12) {
                    // Directionality sits with the geometry: this is the only screen that
                    // can change it, and a segment's shape and its direction of travel are
                    // usually corrected in the same sitting.
                    Toggle(isOn: $isOneWay) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("One-way").font(.subheadline)
                            Text(directionalityCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // A direction-tagged edge is one-way by definition and the server
                    // rejects the other combination, so lock it rather than offer a switch
                    // that can only fail.
                    .disabled(edge.direction != nil)

                    // Coordinate of map center
                    Text(String(format: "%.6f,  %.6f",
                                centerCoordinate.latitude, centerCoordinate.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if waypoints.isEmpty {
                        Text("No waypoints — add one using the button below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        // Navigation row
                        HStack {
                            Button {
                                guard selectedIndex > 0 else { return }
                                selectedIndex -= 1
                                flyToSelected()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedIndex == 0)

                            Spacer()
                            Text("Point \(selectedIndex + 1) of \(waypoints.count)")
                                .font(.subheadline.bold())
                            Spacer()

                            Button {
                                guard selectedIndex < waypoints.count - 1 else { return }
                                selectedIndex += 1
                                flyToSelected()
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedIndex == waypoints.count - 1)
                        }
                    }

                    // Snap to roads — the repair path for an edge with no usable geometry.
                    // A head/tail stop insert before this shipped wrote an empty polyline
                    // (e.g. UPLB_KANAN_SEG8, Animal Science → CEAT), and a 2-point polyline
                    // is a straight chord; neither is editable point-by-point, so offer to
                    // fetch the real road route between the edge's two stations instead.
                    if waypoints.count < 3, fromCoordinate != nil, toCoordinate != nil {
                        Button {
                            Task { await snapToRoads() }
                        } label: {
                            if isSnapping {
                                HStack { ProgressView(); Text("Fetching road route…") }
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Snap to Roads", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSnapping || isSaving)
                    }

                    // Action buttons
                    HStack(spacing: 8) {
                        if !waypoints.isEmpty {
                            Button("Move here") {
                                waypoints[selectedIndex] = Coordinates(
                                    lat: centerCoordinate.latitude,
                                    lng: centerCoordinate.longitude
                                )
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }

                        Button {
                            let newPoint = Coordinates(
                                lat: centerCoordinate.latitude,
                                lng: centerCoordinate.longitude
                            )
                            if waypoints.isEmpty {
                                waypoints.append(newPoint)
                                selectedIndex = 0
                            } else {
                                waypoints.insert(newPoint, at: selectedIndex + 1)
                                selectedIndex += 1
                            }
                        } label: {
                            Label("Insert", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        if !waypoints.isEmpty {
                            Button {
                                guard waypoints.count > 2 else { return }
                                waypoints.remove(at: selectedIndex)
                                selectedIndex = min(selectedIndex, waypoints.count - 1)
                                flyToSelected()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .disabled(waypoints.count <= 2)
                        }
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Cancel / Save
                    HStack(spacing: 12) {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Save Polyline")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(isSaving || waypoints.count < 2)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
    }

    private var directionalityCaption: String {
        if let direction = edge.direction {
            return "Always one-way — this segment is tagged \(direction.capitalized)."
        }
        return isOneWay
            ? "Served in the \(fromName) → \(toName) direction only."
            : "Riders can travel this segment both ways."
    }

    private func flyToSelected() {
        guard selectedIndex < waypoints.count else { return }
        let wp = waypoints[selectedIndex]
        let coord = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lng)
        withAnimation {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: coord, distance: cameraDistance, heading: 0, pitch: 0
            ))
        }
    }

    /// Replaces the waypoints with the real road route between this edge's two stations.
    /// Loads them into the editor rather than saving directly, so the admin sees what they
    /// are about to commit and can still nudge a point before pressing Save.
    private func snapToRoads() async {
        guard let fromCoordinate, let toCoordinate else { return }
        isSnapping = true
        errorMessage = nil

        let path = await DirectionsGateway.shared.path(
            from: fromCoordinate, to: toCoordinate,
            transport: DirectionsTransport.snapType(for: edge.mkDirectionsTransportType),
            urgency: .interactive
        )
        isSnapping = false

        guard let path, path.coordinates.count >= 2 else {
            errorMessage = "Couldn't fetch a road route for this segment. Try again in a moment."
            return
        }
        // Pin the ends to the stations themselves: MKDirections snaps its endpoints to the
        // nearest road, and the map draws stop pins from the station coordinates, so any
        // drift renders as a gap between the pin and the line.
        var snapped = path.coordinates
        snapped[0] = fromCoordinate
        snapped[snapped.count - 1] = toCoordinate

        waypoints = snapped
        selectedIndex = 0
        flyToSelected()
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await onSave(waypoints, isOneWay)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Save failed. Try again."
        }
        isSaving = false
    }
}
