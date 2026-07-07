//
//  AdminRoutesView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI
import MapKit

// MARK: - ViewModel

@Observable
@MainActor
final class AdminRoutesViewModel {

    struct LineGroup: Identifiable {
        let id: String          // e.g. "MRT-3", "LRT-1"
        var stations: [Station]
    }

    var lineGroups: [LineGroup] = []
    var errorMessage: String?
    var enforceOperatingHours: Bool = true
    var isLoadingSettings: Bool = false
    var settingsError: String?

    func load() {
        Task { await loadSettings() }
        switch GraphLoader.load() {
        case .success(let graph):
            var dict: [String: [Station]] = [:]
            for station in graph.stations {
                dict[station.line, default: []].append(station)
            }
            lineGroups = dict
                .map { LineGroup(id: $0.key, stations: $0.value.sorted { $0.name < $1.name }) }
                .sorted { $0.id < $1.id }
        case .failure:
            errorMessage = "Failed to load transit data."
        }
    }

    func updateStation(_ station: Station, update: StationUpdate) async throws {
        let serverStation = try await AdminService.shared.updateStation(id: station.id, update: update)
        for i in lineGroups.indices {
            guard let j = lineGroups[i].stations.firstIndex(where: { $0.id == station.id }) else { continue }
            let local = lineGroups[i].stations[j]
            // Merge server data with local-only field (interchangesWith not returned by server)
            lineGroups[i].stations[j] = Station(
                id: serverStation.id,
                name: serverStation.name,
                shortName: serverStation.shortName,
                line: local.line,
                type: local.type,
                coordinates: serverStation.coordinates,
                isTerminal: local.isTerminal,
                isInterchange: local.isInterchange,
                interchangesWith: local.interchangesWith,
                amenities: local.amenities,
                operatingHours: serverStation.operatingHours
            )
            persistToLocalGraph(serverStation, preserving: local)
            break
        }
    }

    func loadSettings() async {
        isLoadingSettings = true
        settingsError = nil
        do {
            let settings = try await AdminService.shared.fetchSettings()
            enforceOperatingHours = settings.enforceOperatingHours
        } catch {
            settingsError = "Couldn't load settings."
        }
        isLoadingSettings = false
    }

    func setEnforceOperatingHours(_ value: Bool) async {
        isLoadingSettings = true
        settingsError = nil
        do {
            let settings = try await AdminService.shared.updateSettings(enforceOperatingHours: value)
            enforceOperatingHours = settings.enforceOperatingHours
            await GraphService.shared.forceSync()
        } catch {
            settingsError = "Failed to update setting."
        }
        isLoadingSettings = false
    }

    // Writes the updated station back to the Documents-directory graph JSON so
    // the routing engine picks up the change immediately via TransitDataDidUpdate.
    private func persistToLocalGraph(_ serverStation: Station, preserving local: Station) {
        guard case .success(let graph) = GraphLoader.load(),
              let idx = graph.stations.firstIndex(where: { $0.id == serverStation.id }),
              let url = GraphLoader.documentsURL() else { return }

        let merged = Station(
            id: serverStation.id,
            name: serverStation.name,
            shortName: serverStation.shortName,
            line: local.line,
            type: local.type,
            coordinates: serverStation.coordinates,
            isTerminal: local.isTerminal,
            isInterchange: local.isInterchange,
            interchangesWith: local.interchangesWith,
            amenities: local.amenities,
            operatingHours: serverStation.operatingHours
        )

        var stations = graph.stations
        stations[idx] = merged
        let updated = TransitGraph(
            version: graph.version,
            stations: stations,
            edges: graph.edges,
            peakHourMultipliers: graph.peakHourMultipliers,
            transportModes: graph.transportModes,
            paymentMethods: graph.paymentMethods,
            enforceOperatingHours: graph.enforceOperatingHours
        )

        guard let data = try? JSONEncoder().encode(updated) else { return }
        try? data.write(to: url)
        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }
}

// MARK: - Root: list of lines

struct AdminRoutesView: View {
    @State private var vm = AdminRoutesViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let error = vm.errorMessage {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if vm.lineGroups.isEmpty {
                    ProgressView("Loading routes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("Settings") {
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { vm.enforceOperatingHours },
                                    set: { newValue in Task { await vm.setEnforceOperatingHours(newValue) } }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Enforce Operating Hours")
                                        if let err = vm.settingsError {
                                            Text(err)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                                .disabled(vm.isLoadingSettings)
                                if vm.isLoadingSettings {
                                    ProgressView()
                                        .padding(.leading, 4)
                                }
                            }
                        }
                        Section {
                            NavigationLink(destination: AdminEdgesView()) {
                                Label("Edit Polylines", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
                            }
                        }
                        Section("Lines") {
                            ForEach(vm.lineGroups) { group in
                                NavigationLink(destination: StationListView(group: group, vm: vm)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.id)
                                            .font(.headline)
                                        Text("\(group.stations.count) stations")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Manage Routes")
            .onAppear { vm.load() }
        }
    }
}

// MARK: - Station list for a single line

private struct StationListView: View {
    let group: AdminRoutesViewModel.LineGroup
    let vm: AdminRoutesViewModel
    @State private var selectedStation: Station?
    @State private var searchQuery = ""

    private var currentStations: [Station] {
        vm.lineGroups.first(where: { $0.id == group.id })?.stations ?? group.stations
    }

    private var filtered: [Station] {
        guard !searchQuery.isEmpty else { return currentStations }
        return currentStations.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        List(filtered) { station in
            StationCoordRow(station: station)
                .contentShape(Rectangle())
                .onTapGesture { selectedStation = station }
        }
        .searchable(text: $searchQuery, prompt: "Search stations")
        .listStyle(.insetGrouped)
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedStation) { station in
            EditStationView(station: station) { update in
                try await vm.updateStation(station, update: update)
            }
        }
    }
}

// MARK: - Row

private struct StationCoordRow: View {
    let station: Station

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(station.name).font(.headline)
                if station.isInterchange {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            Text(String(format: "%.6f,  %.6f", station.coordinates.lat, station.coordinates.lng))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Edit view (location map + details form)

private struct EditStationView: View {
    let station: Station
    let onSave: (StationUpdate) async throws -> Void

    enum Tab: String, CaseIterable {
        case location = "Location"
        case details  = "Details"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .location

    // Location tab
    @State private var cameraPosition: MapCameraPosition
    @State private var centerCoordinate: CLLocationCoordinate2D

    // Details tab
    @State private var name: String
    @State private var shortName: String
    @State private var openTime: String
    @State private var closeTime: String

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
        _name      = State(initialValue: station.name)
        _shortName = State(initialValue: station.shortName)
        _openTime  = State(initialValue: station.operatingHours.open)
        _closeTime = State(initialValue: station.operatingHours.close)
    }

    var body: some View {
        ZStack {
            // Background layer
            if selectedTab == .location {
                Map(position: $cameraPosition)
                    .onMapCameraChange(frequency: .continuous) { ctx in
                        centerCoordinate = ctx.camera.centerCoordinate
                    }
                    .ignoresSafeArea()
            } else {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
            }

            // Center pin (location tab only)
            if selectedTab == .location {
                VStack(spacing: 0) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    Rectangle()
                        .fill(.blue)
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

                // Details form (fills remaining space on details tab)
                if selectedTab == .details {
                    detailsForm
                } else {
                    Spacer()
                }

                // Error
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 4)
                }

                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                // Cancel / Confirm
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
            closeTime: closeTime != station.operatingHours.close  ? closeTime : nil
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
