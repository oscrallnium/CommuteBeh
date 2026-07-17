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

    func updateEdge(_ edge: TransitEdge, polylineCoordinates: [Coordinates]) async throws {
        let updated = try await AdminService.shared.updateEdge(
            id: edge.id, polylineCoordinates: polylineCoordinates
        )
        for i in lineGroups.indices {
            guard let j = lineGroups[i].edges.firstIndex(where: { $0.id == edge.id }) else { continue }
            lineGroups[i].edges[j] = updated
            persistToLocalGraph(edgeId: edge.id, polylineCoordinates: updated.polylineCoordinates)
            break
        }
    }

    private func persistToLocalGraph(edgeId: String, polylineCoordinates: [Coordinates]) {
        guard case .success(let graph) = GraphLoader.load(),
              let idx = graph.edges.firstIndex(where: { $0.id == edgeId }),
              let url = GraphLoader.documentsURL() else { return }

        let old = graph.edges[idx]
        let updatedEdge = TransitEdge(
            id: old.id, from: old.from, to: old.to, mode: old.mode, line: old.line,
            travelTimeMinutes: old.travelTimeMinutes, distanceKm: old.distanceKm,
            baseFare: old.baseFare, farePerKm: old.farePerKm,
            acceptedPayments: old.acceptedPayments, isAirConditioned: old.isAirConditioned,
            crowdFactor: old.crowdFactor, reliability: old.reliability,
            bidirectional: old.bidirectional, direction: old.direction,
            polylineCoordinates: polylineCoordinates,
            mkDirectionsTransportType: old.mkDirectionsTransportType,
            isRoadSnapped: old.isRoadSnapped
        )
        var edges = graph.edges
        edges[idx] = updatedEdge
        let newGraph = TransitGraph(
            version: graph.version, stations: graph.stations, edges: edges,
            peakHourMultipliers: graph.peakHourMultipliers,
            transportModes: graph.transportModes, paymentMethods: graph.paymentMethods,
            enforceOperatingHours: graph.enforceOperatingHours
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

    var body: some View {
        List(currentEdges) { edge in
            EdgeRow(
                edge: edge,
                fromName: vm.stationName(for: edge.from),
                toName: vm.stationName(for: edge.to)
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedEdge = edge }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedEdge) { edge in
            EditEdgePolylineView(
                edge: edge,
                fromName: vm.stationName(for: edge.from),
                toName: vm.stationName(for: edge.to)
            ) { newCoords in
                try await vm.updateEdge(edge, polylineCoordinates: newCoords)
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
            Text("\(edge.polylineCoordinates.count) waypoints")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Polyline editor

private struct EditEdgePolylineView: View {
    let edge: TransitEdge
    let fromName: String
    let toName: String
    let onSave: ([Coordinates]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waypoints: [Coordinates]
    @State private var selectedIndex: Int
    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var cameraDistance: CLLocationDistance = 500
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(edge: TransitEdge, fromName: String, toName: String,
         onSave: @escaping ([Coordinates]) async throws -> Void) {
        self.edge = edge
        self.fromName = fromName
        self.toName = toName
        self.onSave = onSave
        let coords = edge.polylineCoordinates
        _waypoints = State(initialValue: coords)
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

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await onSave(waypoints)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Save failed. Try again."
        }
        isSaving = false
    }
}
