//
//  EditStationView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import SwiftUI
import MapKit

// MARK: - Edit view (location map + details form)

struct EditStationView: View {
    let station: Station
    let onSave: (StationUpdate) async throws -> Void

    enum Tab: String, CaseIterable {
        case location = "Location"
        case access   = "Access"
        case details  = "Details"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .location

    // Location tab
    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D

    // Access tab — the station's doors, edited as a list and saved as a whole set.
    @State private var accessPoints: [StationAccessPoint]
    /// Door currently being positioned on the map, if any. While non-nil the map's
    /// crosshair moves that door instead of the station centroid.
    @State private var editingAccessPointID: StationAccessPoint.ID?

    // Details tab
    @State private var name: String
    @State private var shortName: String
    @State private var openTime: String
    @State private var closeTime: String
    @State private var boarding: Station.Boarding

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(station: Station, onSave: @escaping (StationUpdate) async throws -> Void) {
        self.station = station
        self.onSave = onSave
        let coord = CLLocationCoordinate2D(
            latitude: station.coordinates.lat,
            longitude: station.coordinates.lng
        )
        _cameraPosition = State(initialValue: .camera(
            MapCamera(centerCoordinate: coord, distance: 400, heading: 0, pitch: 0)
        ))
        _centerCoordinate = State(initialValue: coord)
        _accessPoints = State(initialValue: station.accessPoints ?? [])
        _name      = State(initialValue: station.name)
        _shortName = State(initialValue: station.shortName)
        _openTime  = State(initialValue: station.operatingHours.open)
        _closeTime = State(initialValue: station.operatingHours.close)
        _boarding  = State(initialValue: station.boarding ?? .both)
    }

    var body: some View {
        ZStack {
            // Background layer
            if selectedTab == .location || selectedTab == .access {
                Map(position: $cameraPosition) {
                    // Every door at once, plus the centroid — placing one against a blank
                    // map is how the existing coordinates ended up hundreds of metres out.
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: station.coordinates.lat, longitude: station.coordinates.lng)) {
                        Circle().fill(Color.slate.opacity(0.5))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    ForEach(accessPoints) { point in
                        // The one being positioned is hidden: the crosshair is standing in
                        // for it, and drawing both would show it in two places at once.
                        if point.id != editingAccessPointID {
                            Annotation(point.name, coordinate: CLLocationCoordinate2D(
                                latitude: point.coordinates.lat, longitude: point.coordinates.lng)) {
                                Image(systemName: point.kind.symbol)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(point.directionTint))
                                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            }
                        }
                    }
                }
                .onMapCameraChange(frequency: .continuous) { ctx in
                    centerCoordinate = ctx.camera.centerCoordinate
                }
                .ignoresSafeArea()
            } else {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
            }

            // Center pin — the station centroid on the Location tab, and the door being
            // positioned on the Access tab.
            if selectedTab == .location || editingAccessPointID != nil {
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.onyx)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.canvas, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    Rectangle()
                        .fill(Color.onyx)
                        .frame(width: 2, height: 10)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
            }

            // Chrome overlay
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name).font(.headline)
                        if selectedTab == .location {
                            Text(String(format: "%.6f,  %.6f",
                                        centerCoordinate.latitude,
                                        centerCoordinate.longitude))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(station.line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 56)

                // Tab body (fills remaining space)
                if selectedTab == .details {
                    detailsForm
                } else if selectedTab == .access, editingAccessPointID == nil {
                    accessList
                } else {
                    Spacer()
                }

                // Error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.vermilion)
                        .padding(8)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 4)
                }

                // Tab picker — hidden while positioning a door, since leaving the tab
                // would abandon a placement the crosshair is still standing in for.
                if editingAccessPointID == nil {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                }

                // Cancel / Confirm — replaced by the placement controls while a door is
                // being positioned, so "Confirm" never means two things at once.
                if editingAccessPointID != nil {
                    accessPlacementBar
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                } else {
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button {
                        Task { await confirm() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Confirm")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(isSaving)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: Access tab — add / edit / remove doors

    /// The station's doors. Each row carries the two facts that decide when it is used:
    /// whether it is an entrance, an exit or both, and which travel direction it serves.
    private var accessList: some View {
        List {
            Section {
                if accessPoints.isEmpty {
                    Text("No access points. The station's own coordinate is used for every walk to or from it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($accessPoints) { $point in
                    VStack(alignment: .leading, spacing: 8) {
                        // Bound through setters, not `$point.name`: the model is an
                        // immutable value type like every other in the domain layer.
                        TextField("Name (e.g. Taft Ave footbridge)", text: Binding(
                            get: { point.name },
                            set: { point = point.settingName($0) }
                        ))
                        .font(.subheadline.weight(.semibold))

                        Picker("Kind", selection: Binding(
                            get: { point.kind },
                            set: { point = point.settingKind($0) }
                        )) {
                            Text("Entrance").tag(StationAccessPoint.Kind.entrance)
                            Text("Exit").tag(StationAccessPoint.Kind.exit)
                            Text("Both").tag(StationAccessPoint.Kind.both)
                        }
                        .pickerStyle(.segmented)

                        // nil == serves every direction. That is the common case, not a
                        // fallback: only MRT-3 has directional edges at all, so a door on
                        // any other line can never be matched to one.
                        Picker("Direction", selection: Binding(
                            get: { point.direction ?? "" },
                            set: { point = point.settingDirection($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Both directions").tag("")
                            Text("Northbound").tag("northbound")
                            Text("Southbound").tag("southbound")
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text(String(format: "%.6f,  %.6f",
                                        point.coordinates.lat, point.coordinates.lng))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Place on map") {
                                // Fly to the door and hand the crosshair over to it.
                                editingAccessPointID = point.id
                                cameraPosition = .camera(MapCamera(
                                    centerCoordinate: CLLocationCoordinate2D(
                                        latitude: point.coordinates.lat,
                                        longitude: point.coordinates.lng),
                                    distance: 300, heading: 0, pitch: 0))
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { accessPoints.remove(atOffsets: $0) }
            } header: {
                Text("Access Points")
            } footer: {
                Text("Saving replaces this station's full set — a door removed here is deleted on the server. Walks use the nearest door open to the passenger, falling back to the station coordinate when there are none.")
            }

            Section {
                Button {
                    // Placed at the map's current centre rather than at the station, so a
                    // new door lands where the admin is already looking.
                    let new = StationAccessPoint(
                        id: "\(station.id)_AP_\(UUID().uuidString.prefix(8).uppercased())",
                        name: "",
                        kind: .both,
                        direction: nil,
                        coordinates: Coordinates(lat: centerCoordinate.latitude,
                                                 lng: centerCoordinate.longitude))
                    accessPoints.append(new)
                    editingAccessPointID = new.id
                } label: {
                    Label("Add access point", systemImage: "plus.circle.fill")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Shown while a door is being positioned: the crosshair is standing in for it, so the
    /// only controls needed are "keep this spot" and "put it back".
    private var accessPlacementBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                // Discard the move by restoring the coordinate the door had on entry.
                if let id = editingAccessPointID,
                   let idx = accessPoints.firstIndex(where: { $0.id == id }),
                   let original = (station.accessPoints ?? []).first(where: { $0.id == id }) {
                    accessPoints[idx] = accessPoints[idx].settingCoordinates(original.coordinates)
                }
                editingAccessPointID = nil
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button("Set location") {
                if let id = editingAccessPointID,
                   let idx = accessPoints.firstIndex(where: { $0.id == id }) {
                    accessPoints[idx] = accessPoints[idx].settingCoordinates(
                        Coordinates(lat: centerCoordinate.latitude,
                                    lng: centerCoordinate.longitude))
                }
                editingAccessPointID = nil
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    private var detailsForm: some View {
        List {
            Section("Station Info") {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Short Name") {
                    TextField("Short Name", text: $shortName)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Boarding") {
                Picker("Boarding", selection: $boarding) {
                    Text("Pick-up and drop-off").tag(Station.Boarding.both)
                    Text("Drop-off only").tag(Station.Boarding.alightOnly)
                }
                .pickerStyle(.segmented)
            }
            Section("Operating Hours") {
                LabeledContent("Opens") {
                    TextField("05:30", text: $openTime)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                }
                LabeledContent("Closes") {
                    TextField("22:30", text: $closeTime)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func confirm() async {
        isSaving = true
        errorMessage = nil
        let update = StationUpdate(
            latitude:  centerCoordinate.latitude,
            longitude: centerCoordinate.longitude,
            name:      name      != station.name                  ? name      : nil,
            shortName: shortName != station.shortName             ? shortName : nil,
            openTime:  openTime  != station.operatingHours.open   ? openTime  : nil,
            closeTime: closeTime != station.operatingHours.close  ? closeTime : nil,
            // Sent only when the set actually changed: the server replaces wholesale, so
            // resending an unchanged list would delete and recreate every door for nothing.
            accessPoints: accessPoints == (station.accessPoints ?? []) ? nil : accessPoints,
            boarding: boarding != (station.boarding ?? .both) ? boarding : nil
        )
        do {
            try await onSave(update)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Save failed. Try again."
        }
        isSaving = false
    }
}
