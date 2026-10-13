//
//  AdminRoutesViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
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
    var lastStopNumberByLine: [String: Int] = [:]
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
                .map { LineGroup(id: $0.key, stations: StationChain.groups(of: $0.value).flatMap(\.stations)) }
                .sorted { $0.id < $1.id }
            edgesByLine = Dictionary(grouping: graph.edges, by: \.line)
            lastStopNumberByLine = graph.lines.compactMapValues(\.lastStopNumber)
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
                operatingHours: serverStation.operatingHours,
                // From the server, not `local`: unlike interchangesWith, the station
                // endpoint does return access points, so its copy is the fresh one.
                accessPoints: serverStation.accessPoints,
                sequence: serverStation.sequence ?? local.sequence,
                boarding: serverStation.boarding
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
            accessPoints: serverStation.accessPoints,
            sequence: serverStation.sequence ?? local.sequence,
            boarding: serverStation.boarding
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
