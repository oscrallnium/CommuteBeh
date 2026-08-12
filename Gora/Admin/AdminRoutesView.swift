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
    /// Edges keyed by line, so Add Stop can draw the route's existing geometry and
    /// preview the polylines an insert would produce. Stations alone can't show that —
    /// the shape between two stops lives entirely in `TransitEdge.polylineCoordinates`.
    var edgesByLine: [String: [TransitEdge]] = [:]
    var errorMessage: String?
    var enforceOperatingHours: Bool = true
    var isLoadingSettings: Bool = false
    var settingsError: String?
    var isDeletingRoute: Bool = false
    var deleteRouteError: String?

    func load() {
        Task { await loadSettings() }
        switch GraphLoader.load() {
        case .success(let graph):
            var dict: [String: [Station]] = [:]
            for station in graph.stations {
                dict[station.line, default: []].append(station)
            }
            lineGroups = dict
                .map { LineGroup(id: $0.key, stations: Self.inChainOrder($0.value)) }
                .sorted { $0.id < $1.id }
            edgesByLine = Dictionary(grouping: graph.edges, by: \.line)
        case .failure:
            errorMessage = "Failed to load transit data."
        }
    }

    /// Stops in travel order, grouped by chain.
    ///
    /// Previously sorted by name, which is the one order that means nothing on a route —
    /// and this is the screen an admin opens to check a stop sequence. A line can also
    /// hold more than one chain (a northbound and a southbound pass are independent
    /// sequences sharing a line id), so group by the `<prefix>_STOP<n>` prefix first,
    /// then order within a chain by the number the id encodes. Hand-authored ids with no
    /// number — train stations — have no chain position to sort on and keep name order.
    static func inChainOrder(_ stations: [Station]) -> [Station] {
        stations.sorted { a, b in
            let prefixA = StopInsertionPreview.sequencePrefix(a.id) ?? ""
            let prefixB = StopInsertionPreview.sequencePrefix(b.id) ?? ""
            if prefixA != prefixB { return prefixA < prefixB }
            let numberA = StopInsertionPreview.stopNumber(a.id) ?? .max
            let numberB = StopInsertionPreview.stopNumber(b.id) ?? .max
            if numberA != numberB { return numberA < numberB }
            return a.name < b.name
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
                operatingHours: serverStation.operatingHours,
                // From the server, not `local`: unlike interchangesWith, the station
                // endpoint does return access points, so its copy is the fresh one.
                accessPoints: serverStation.accessPoints
            )
            persistToLocalGraph(serverStation, preserving: local)
            break
        }
    }

    /// Inserts a new stop and removing one both cascade across the whole line
    /// (renumbering STOP/SEG ids downstream), so rather than hand-patch the local
    /// graph cache like `updateStation` does, just force a full re-sync — matches
    /// the pattern already used after PolylineRecorderView/LoopCreatorView mutations.
    func insertStation(payload: [String: Any]) async throws {
        _ = try await AdminService.shared.insertStation(payload: payload)
        await GraphService.shared.forceSync()
        load()
    }

    func removeStation(_ station: Station) async throws {
        try await AdminService.shared.deleteStation(id: station.id)
        await GraphService.shared.forceSync()
        load()
    }

    func deleteRoute(_ lineId: String) async {
        isDeletingRoute = true
        deleteRouteError = nil
        do {
            try await AdminService.shared.deleteRoute(lineId: lineId)
            lineGroups.removeAll { $0.id == lineId }
            persistDeletionToLocalGraph(lineId: lineId)
        } catch let error as APIError {
            deleteRouteError = error.userMessage
        } catch {
            deleteRouteError = "Failed to delete route."
        }
        isDeletingRoute = false
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
            operatingHours: serverStation.operatingHours,
            accessPoints: serverStation.accessPoints
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
            lines: graph.lines,
            enforceOperatingHours: graph.enforceOperatingHours
        )

        guard let data = try? JSONEncoder().encode(updated) else { return }
        try? data.write(to: url)
        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }

    // Removes every station and edge on `lineId`, and strips it from each
    // transport mode's `lines` array — mirrors GraphService#delete_route on the backend.
    private func persistDeletionToLocalGraph(lineId: String) {
        guard case .success(let graph) = GraphLoader.load(),
              let url = GraphLoader.documentsURL() else { return }

        let updatedModes = graph.transportModes.mapValues { config -> TransportModeConfig in
            guard config.lines.contains(lineId) else { return config }
            return TransportModeConfig(
                id: config.id,
                displayName: config.displayName,
                pluralName: config.pluralName,
                sfSymbol: config.sfSymbol,
                colorHex: config.colorHex,
                mapLineWidthPt: config.mapLineWidthPt,
                mapLineDash: config.mapLineDash,
                mkDirectionsTransportType: config.mkDirectionsTransportType,
                isUserSelectable: config.isUserSelectable,
                isAlwaysAllowed: config.isAlwaysAllowed,
                lines: config.lines.filter { $0 != lineId },
                defaultAcceptedPayments: config.defaultAcceptedPayments,
                notes: config.notes
            )
        }

        // `lines` is left untouched, not filtered to drop `lineId` — this mirrors
        // GraphService#delete_route, which likewise removes the line's stations/edges
        // and strips it from transport_modes.lines but leaves the Line row behind. A
        // name for a route with no live edges is exactly what already happens for
        // EJEEPNEY_BGC, so an iOS-only cleanup here would just be a second, diverging
        // definition of "deleted" instead of matching the backend's.
        let updated = TransitGraph(
            version: graph.version,
            stations: graph.stations.filter { $0.line != lineId },
            edges: graph.edges.filter { $0.line != lineId },
            peakHourMultipliers: graph.peakHourMultipliers,
            transportModes: updatedModes,
            paymentMethods: graph.paymentMethods,
            lines: graph.lines,
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
    @State private var routeToDelete: AdminRoutesViewModel.LineGroup?

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
                        if let error = vm.deleteRouteError {
                            Section {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
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
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        routeToDelete = group
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .disabled(vm.isDeletingRoute)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .disabled(vm.isDeletingRoute)
                    .overlay {
                        if vm.isDeletingRoute {
                            ProgressView("Deleting route…")
                                .padding(16)
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .navigationTitle("Manage Routes")
            .onAppear { vm.load() }
            .confirmationDialog(
                "Delete \(routeToDelete?.id ?? "") route?",
                isPresented: Binding(
                    get: { routeToDelete != nil },
                    set: { if !$0 { routeToDelete = nil } }
                ),
                presenting: routeToDelete
            ) { group in
                Button("Delete Route", role: .destructive) {
                    let lineId = group.id
                    routeToDelete = nil
                    Task { await vm.deleteRoute(lineId) }
                }
                Button("Cancel", role: .cancel) { routeToDelete = nil }
            } message: { group in
                Text("This permanently removes all \(group.stations.count) stations and every edge on \(group.id). This cannot be undone.")
            }
        }
    }
}

// MARK: - Station list for a single line

private struct StationListView: View {
    let group: AdminRoutesViewModel.LineGroup
    let vm: AdminRoutesViewModel
    @State private var selectedStation: Station?
    @State private var searchQuery = ""
    // Raw lat/lng is noisy for a plain "browse this line's stops" list — hidden by
    // default, revealed on demand via the toolbar toggle below.
    @State private var showCoordinates = false
    @State private var showAddStop = false
    @State private var stationToRemove: Station?
    @State private var isRemovingStop = false
    @State private var removeStopError: String?

    private var currentStations: [Station] {
        vm.lineGroups.first(where: { $0.id == group.id })?.stations ?? group.stations
    }

    private var filtered: [Station] {
        guard !searchQuery.isEmpty else { return currentStations }
        return currentStations.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    /// The line's stops split into their chains, in travel order. More than one means the
    /// line was recorded as a directional pair, and the two are independent sequences —
    /// showing them as one undivided list makes the numbering look like it restarts at
    /// random.
    private var chains: [(prefix: String, stations: [Station])] {
        Dictionary(grouping: filtered) { StopInsertionPreview.sequencePrefix($0.id) ?? $0.line }
            .map { (prefix: $0.key, stations: AdminRoutesViewModel.inChainOrder($0.value)) }
            .sorted { $0.prefix < $1.prefix }
    }

    var body: some View {
        List {
            ForEach(chains, id: \.prefix) { chain in
                Section {
                    ForEach(chain.stations) { station in
                        StationCoordRow(station: station, showCoordinates: showCoordinates)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedStation = station }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    stationToRemove = station
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    if chains.count > 1 {
                        Text(chain.prefix)
                            .font(.caption2.bold())
                            .textCase(nil)
                    }
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search stations")
        .listStyle(.insetGrouped)
        .navigationTitle(group.id)
        .navigationBarTitleDisplayMode(.large)
        .disabled(isRemovingStop)
        .overlay {
            if isRemovingStop {
                ProgressView("Removing stop…")
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddStop = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Stop")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCoordinates.toggle()
                } label: {
                    Image(systemName: showCoordinates ? "eye.slash" : "eye")
                }
                .accessibilityLabel(showCoordinates ? "Hide Coordinates" : "Show Coordinates")
            }
        }
        .fullScreenCover(item: $selectedStation) { station in
            EditStationView(station: station) { update in
                try await vm.updateStation(station, update: update)
            }
        }
        .sheet(isPresented: $showAddStop) {
            AddStopView(
                lineStations: currentStations,
                lineEdges: vm.edgesByLine[group.id] ?? []
            ) { payload in
                try await vm.insertStation(payload: payload)
            }
        }
        .confirmationDialog(
            "Remove \(stationToRemove?.name ?? "")?",
            isPresented: Binding(
                get: { stationToRemove != nil },
                set: { if !$0 { stationToRemove = nil } }
            ),
            presenting: stationToRemove
        ) { station in
            Button("Remove Stop", role: .destructive) {
                let target = station
                stationToRemove = nil
                Task {
                    isRemovingStop = true
                    removeStopError = nil
                    do {
                        try await vm.removeStation(target)
                    } catch let error as APIError {
                        removeStopError = error.userMessage
                    } catch {
                        removeStopError = "Failed to remove stop."
                    }
                    isRemovingStop = false
                }
            }
            Button("Cancel", role: .cancel) { stationToRemove = nil }
        } message: { station in
            Text("This merges the segments on either side of \(station.name) into one and renumbers later stops on this line. This cannot be undone.")
        }
        .alert(
            "Couldn't Remove Stop",
            isPresented: Binding(
                get: { removeStopError != nil },
                set: { if !$0 { removeStopError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeStopError ?? "")
        }
    }
}

// MARK: - Add Stop

/// Tap the route to place a stop. The tap snaps onto the nearest polyline vertex
/// (within `snapRadiusMeters`) because that's exactly where the backend splits the
/// segment — dropping a stop between two vertices leaves the pin visibly off the
/// junction the split produces. The panel then shows the polylines the insert will
/// create, vertex by vertex, before anything is written.
private struct AddStopView: View {
    let lineStations: [Station]
    let lineEdges: [TransitEdge]
    let onSave: ([String: Any]) async throws -> Void

    /// A tap this far (metres) from a polyline vertex snaps onto it. Roughly the width
    /// of an intersection — close enough that the admin meant that vertex, far enough
    /// that a deliberate off-route placement still survives.
    private static let snapRadiusMeters: CLLocationDistance = 25

    @Environment(\.dismiss) private var dismiss
    @State private var referenceStationId: String
    @State private var selectedChainPrefix: String
    @State private var position: String = "after"
    @State private var name = ""
    @State private var cameraPosition: MapCameraPosition
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var snapEnabled = true
    @State private var expandedPolylineID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Fetching road geometry for a head/tail insert's new segment.
    @State private var isFetchingGeometry = false
    /// Set after a failed geometry fetch, so a second Save tap goes through anyway.
    @State private var allowSaveWithoutGeometry = false
    /// Fetched road route per new edge, in creation order and oriented from → to. Drives
    /// both the preview and what gets posted, so the two can never disagree.
    @State private var roadGeometry: [[Coordinates]] = []

    /// The line's independent stop sequences, keyed by `<prefix>_STOP<n>` prefix.
    static func chains(of stations: [Station]) -> [(prefix: String, stations: [Station])] {
        Dictionary(grouping: stations) { StopInsertionPreview.sequencePrefix($0.id) ?? $0.line }
            .map { (prefix: $0.key, stations: StopInsertionPreview.orderedChain($0.value)) }
            .sorted { $0.prefix < $1.prefix }
    }

    private var chains: [(prefix: String, stations: [Station])] { Self.chains(of: lineStations) }

    /// Every insert is scoped to one chain.
    ///
    /// Feeding the whole line in made a directional pair collapse into one list —
    /// `orderedChain` breaks ties on the stop number by array order, so `NB_STOP1` and
    /// `SB_STOP1` interleaved. An insert after `NB_STOP2` then read its neighbours as
    /// `NB_STOP2` and `SB_STOP2`, found no edge between them, and reported "no polyline
    /// preview — the backend may reject inserting here", which is the opposite of true:
    /// the backend scopes by prefix and inserts correctly. Scoping here makes the preview
    /// describe what will actually happen.
    private var orderedStations: [Station] {
        chains.first { $0.prefix == selectedChainPrefix }?.stations ?? []
    }

    /// Edges belonging to the selected chain — both endpoints inside it.
    private var chainEdges: [TransitEdge] {
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
        ), !segment.coordinates.isEmpty {
            return [segment.coordinates]
        }
        return linePolylines
    }

    /// The tap after snapping — nil until the admin has placed the stop.
    private var snap: StopInsertionPreview.SnapResult? {
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

    private var placedCoordinate: CLLocationCoordinate2D? { snap?.coordinate }

    /// The endpoints of every new edge that needs its own fetched road route, in creation
    /// order. Empty when the server can slice existing geometry instead.
    ///
    /// Orientation matters: the server stores what it is given, and a reversed polyline
    /// draws the route running backwards.
    ///
    /// - head/tail insert → one edge (new stop ↔ its only neighbour)
    /// - mid-chain insert into a segment with **no** polyline → two edges, since there is
    ///   nothing to slice (this is the state a pre-fix head/tail insert left behind)
    /// - mid-chain insert into a real polyline → none; the server splits it
    private func neededChords(for coordinate: CLLocationCoordinate2D)
    -> [(from: Coordinates, to: Coordinates)] {
        let ordered = orderedStations
        guard let refIndex = ordered.firstIndex(where: { $0.id == referenceStationId }) else { return [] }
        let p = position == "after" ? refIndex + 2 : refIndex + 1
        let new = Coordinates(lat: coordinate.latitude, lng: coordinate.longitude)

        if p == 1, let head = ordered.first {
            return [(new, head.coordinates)]                // new stop → old first stop
        }
        if p == ordered.count + 1, let tail = ordered.last {
            return [(tail.coordinates, new)]                // old last stop → new stop
        }
        guard p > 1, p <= ordered.count else { return [] }

        let previous = ordered[p - 2]
        let next = ordered[p - 1]
        let existing = StopInsertionPreview.edge(from: previous.id, to: next.id, in: chainEdges)?.coordinates ?? []
        guard existing.isEmpty else { return [] }           // real geometry — server slices it
        return [(previous.coordinates, new), (new, next.coordinates)]
    }

    private var preview: StopInsertionPreview.Result? {
        guard let placedCoordinate else { return nil }
        return StopInsertionPreview.make(
            coordinate: placedCoordinate,
            referenceStationID: referenceStationId,
            position: position,
            stations: orderedStations,
            edges: chainEdges,
            roadGeometry: roadGeometry
        )
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
    private func refreshRoadGeometry() async {
        guard let placedCoordinate else { return }
        let chords = neededChords(for: placedCoordinate)
        guard !chords.isEmpty else { return }

        let requestedKey = roadGeometryKey
        let transport = DirectionsTransport.snapType(for: chainEdges.first?.mkDirectionsTransportType)
        isFetchingGeometry = true
        defer { isFetchingGeometry = false }

        var fetched: [[Coordinates]] = []
        for chord in chords {
            guard let path = await DirectionsGateway.shared.path(
                from: chord.from, to: chord.to, transport: transport, urgency: .interactive
            ), path.coordinates.count >= 3 else { break }
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

    init(lineStations: [Station], lineEdges: [TransitEdge],
         onSave: @escaping ([String: Any]) async throws -> Void) {
        self.lineStations = lineStations
        self.lineEdges = lineEdges
        self.onSave = onSave
        let chains = Self.chains(of: lineStations)
        let firstChain = chains.first
        _selectedChainPrefix = State(initialValue: firstChain?.prefix ?? "")
        _referenceStationId = State(initialValue: firstChain?.stations.first?.id ?? "")
        // Open framed on the chain being edited, not on one stop — placement is by tapping
        // the route, so it has to be on screen before the admin can do anything.
        _cameraPosition = State(
            initialValue: .region(Self.region(spanning: firstChain?.stations ?? lineStations))
        )
    }

    private static func region(spanning stations: [Station]) -> MKCoordinateRegion {
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

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition) {
            // Existing geometry, dimmed — the segment about to be replaced is drawn
            // separately below so it reads as "this is what's going away".
            ForEach(chainEdges) { edge in
                if edge.polylineCoordinates.count >= 2, edge.id != preview?.replacedEdge?.id {
                    MapPolyline(coordinates: edge.polylineCoordinates.map(\.clCoordinate))
                        .stroke(.gray.opacity(0.55), lineWidth: 3)
                }
            }

            if let replaced = preview?.replacedEdge, replaced.coordinates.count >= 2 {
                MapPolyline(coordinates: replaced.coordinates.map(\.clCoordinate))
                    .stroke(.red.opacity(0.35), style: StrokeStyle(lineWidth: 7, dash: [2, 6]))
            }

            // The polylines this insert creates.
            ForEach(Array((preview?.newPolylines ?? []).enumerated()), id: \.element.id) { index, poly in
                if poly.coordinates.count >= 2 {
                    MapPolyline(coordinates: poly.coordinates.map(\.clCoordinate))
                        // Solid, always: every polyline drawn here is real geometry —
                        // sliced from the existing segment or fetched from MKDirections.
                        // The dashed style used to mean "straight chord", which is no
                        // longer a thing this view can produce.
                        .stroke(
                            index == 0 ? Color.green : Color.orange,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
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
                Annotation(station.name, coordinate: station.coordinates.clCoordinate) {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.gray, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }

            // Where the tap landed before snapping, so the snap itself is visible.
            if let snap, snap.didSnap {
                Annotation("", coordinate: snap.tapped) {
                    Circle()
                        .strokeBorder(.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 16, height: 16)
                }
                MapPolyline(coordinates: [snap.tapped, snap.coordinate])
                    .stroke(.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }

            if let placedCoordinate {
                Annotation(name.isEmpty ? "New stop" : name, coordinate: placedCoordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .background(Circle().fill(.white).frame(width: 16, height: 16))
                }
            }
        }
    }

    /// Green for the vertices of the first new polyline, orange for the second — matching
    /// the strokes — with the shared split vertex drawn once, larger and in blue, on top.
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
                    color: index == 0 ? .green : .orange
                )
            }
        }
        let stride = max(1, all.count / Self.maxVertexMarkers)
        var markers = stride == 1 ? all : all.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        if let splitVertex = preview.splitVertex {
            markers.append(VertexMarker(
                id: "split", coordinate: splitVertex.clCoordinate, color: .blue, isJunction: true
            ))
        }
        return markers
    }

    // MARK: - Panels

    private var instructionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
            Text("Tap the route to place the stop")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
    }

    private var formPanel: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 12) {
                    coordinateReadout

                    TextField("Stop name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Picker("Position", selection: $position) {
                        Text("Before").tag("before")
                        Text("After").tag("after")
                    }
                    .pickerStyle(.segmented)

                    // A directional line holds two independent chains; an insert applies to
                    // exactly one of them, so it has to be chosen before anything else
                    // makes sense.
                    if chains.count > 1 {
                        Picker("Direction", selection: $selectedChainPrefix) {
                            ForEach(chains, id: \.prefix) { chain in
                                Text(chain.prefix).tag(chain.prefix)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedChainPrefix) { _, _ in
                            referenceStationId = orderedStations.first?.id ?? ""
                            tappedCoordinate = nil
                        }
                    }

                    Picker("Reference stop", selection: $referenceStationId) {
                        ForEach(orderedStations) { station in
                            Text(station.name).tag(station.id)
                        }
                    }
                    .pickerStyle(.menu)

                    polylinePreviewSection
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 360)

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    HStack {
                        ProgressView().tint(.white)
                        Text(isFetchingGeometry ? "Fetching road route…" : "Adding…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(allowSaveWithoutGeometry ? "Add Stop Without Road Geometry" : "Add Stop")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            // Disabled while the road route is in flight: saving mid-fetch would take the
            // "no geometry" path and ask the admin to override something that is seconds
            // from arriving.
            .disabled(isSaving || isFetchingGeometry || placedCoordinate == nil
                      || name.trimmingCharacters(in: .whitespaces).isEmpty
                      || referenceStationId.isEmpty)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    private var coordinateReadout: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: placedCoordinate == nil ? "mappin.slash" : "mappin.circle.fill")
                    .foregroundStyle(placedCoordinate == nil ? Color.secondary : Color.blue)
                Text(placedCoordinate.map { String(format: "%.6f,  %.6f", $0.latitude, $0.longitude) }
                     ?? "No location placed yet")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(placedCoordinate == nil ? Color.secondary : Color.primary)
                Spacer()
            }

            if let snap, snap.didSnap, let distance = snap.snappedDistanceMeters {
                HStack {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundStyle(.green)
                    Text(String(format: "Snapped %.1f m onto a polyline point", distance))
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Spacer()
                }
            } else if placedCoordinate != nil {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Text(snapEnabled
                         ? "No polyline point within \(Int(Self.snapRadiusMeters)) m — using the exact tap."
                         : "Snapping off — using the exact tap.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Toggle(isOn: $snapEnabled) {
                Text("Snap to polyline points")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var polylinePreviewSection: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Polylines created")
                        .font(.caption.bold())
                    Spacer()
                    Text(preview.newStationID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let replaced = preview.replacedEdge {
                    Text("Replaces \(replaced.id) · \(replaced.coordinates.count) pts"
                         + (preview.splitVertexIndex.map { " · split at point \($0 + 1)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(preview.newPolylines.enumerated()), id: \.element.id) { index, poly in
                    polylineRow(poly, color: index == 0 ? .green : .orange)
                }

                if let warning = preview.warning {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(warning)
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if placedCoordinate != nil {
            Text("No polyline preview for this position — the backend may reject inserting here.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func polylineRow(_ poly: StopInsertionPreview.NewPolyline, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedPolylineID = expandedPolylineID == poly.id ? nil : poly.id
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 14, height: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(poly.fromName) → \(poly.toName)")
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(poly.id) · \(poly.coordinates.count) pts · "
                             + String(format: "%.2f km", poly.lengthKm)
                             + (poly.isFetched ? " · road route" : " · sliced"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expandedPolylineID == poly.id ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expandedPolylineID == poly.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(poly.coordinates.enumerated()), id: \.offset) { i, point in
                            Text(String(format: "%2d  %.6f, %.6f", i + 1, point.lat, point.lng))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(
                                    isNewStopVertex(point) ? Color.blue : Color.secondary
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    /// Highlights the vertex that coincides with the stop being added — after snapping
    /// that's the shared junction both halves keep.
    private func isNewStopVertex(_ point: Coordinates) -> Bool {
        guard let placedCoordinate else { return false }
        return abs(point.lat - placedCoordinate.latitude) < 1e-9
            && abs(point.lng - placedCoordinate.longitude) < 1e-9
    }

    // MARK: - Actions

    /// Places the stop and re-points the reference picker at the segment the tap landed
    /// on, so the previewed split matches where the admin actually tapped instead of
    /// whichever pair the picker was left on.
    private func place(_ coordinate: CLLocationCoordinate2D) {
        tappedCoordinate = coordinate

        let candidates = StopInsertionPreview.nearestSegmentStarts(
            to: coordinate, stations: orderedStations, edges: chainEdges
        )
        guard let nearest = candidates.first, nearest.distanceMeters <= 150 else { return }

        // Two segments passing within a few metres of the tap means the route doubles back
        // here and the tap genuinely doesn't say which one is meant. Leave the pickers on
        // the admin's explicit choice rather than guessing between the outbound and return
        // side — guessing is precisely how a stop ends up on the wrong side of the road.
        let isAmbiguous = candidates.count > 1
            && abs(candidates[1].distanceMeters - nearest.distanceMeters) < 5
        guard !isAmbiguous else { return }

        referenceStationId = nearest.station.id
        position = "after"
    }

    private func save() async {
        guard let placedCoordinate else { return }
        isSaving = true
        errorMessage = nil
        var payload: [String: Any] = [
            "referenceStationId": referenceStationId,
            "position": position,
            "name": name.trimmingCharacters(in: .whitespaces),
            "lat": placedCoordinate.latitude,
            "lng": placedCoordinate.longitude
        ]

        // A head/tail insert has no existing segment to slice, so unless the road route is
        // sent the new edge is written with an empty polyline — which is what left
        // UPLB_KANAN_SEG8 (Animal Science → CEAT) with 0 waypoints. A mid-chain insert
        // needs nothing: the server splits the existing recorded polyline.
        //
        // Post exactly the geometry the preview drew (`preview.newPolylines`, already
        // end-pinned) rather than re-fetching — what was approved on screen is what gets
        // written, and a second fetch could quietly return something else.
        if !neededChords(for: placedCoordinate).isEmpty {
            let drawn = (preview?.newPolylines ?? []).filter(\.isFetched)
            if drawn.count == neededChords(for: placedCoordinate).count,
               drawn.allSatisfy({ $0.coordinates.count >= 3 }) {
                payload["newEdgePolylines"] = drawn.map { poly in
                    poly.coordinates.map { ["lat": $0.lat, "lng": $0.lng] }
                }
            } else if !allowSaveWithoutGeometry {
                // Don't quietly write the straight chord this whole change exists to avoid.
                // The admin can override on the next tap — data entry shouldn't be blocked
                // by a transient MapKit failure, but it should be a decision, not a default.
                allowSaveWithoutGeometry = true
                errorMessage = "No road route for the new segment yet. Tap Save again to add the stop without it — the segment will draw nothing until you snap it in the edge editor."
                isSaving = false
                return
            }
        }

        do {
            try await onSave(payload)
            dismiss()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Failed to add stop."
        }
        isSaving = false
    }
}

private extension Coordinates {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

// MARK: - Row

private struct StationCoordRow: View {
    let station: Station
    let showCoordinates: Bool

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
            if showCoordinates {
                Text(String(format: "%.6f,  %.6f", station.coordinates.lat, station.coordinates.lng))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
                        Circle().fill(.gray.opacity(0.5))
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
                        .foregroundStyle(.red)
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
            accessPoints: accessPoints == (station.accessPoints ?? []) ? nil : accessPoints
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
