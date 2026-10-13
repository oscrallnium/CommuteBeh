//
//  StationListView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/7/26.
//

import SwiftUI
import MapKit

// MARK: - Station list for a single line

struct StationListView: View {
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
        StationChain.groups(of: filtered)
    }

    /// Each stop's 1-based position in its chain. Counted before the search filter, so a
    /// filtered list keeps the real stop numbers.
    private var stopNumbers: [StationID: Int] {
        var numbers: [StationID: Int] = [:]
        for chain in StationChain.groups(of: currentStations) {
            for (index, station) in chain.stations.enumerated() { numbers[station.id] = index + 1 }
        }
        return numbers
    }

    /// The first stop of a chain that closes into a loop, or nil for an open chain. Pass the
    /// unfiltered chain: a filtered one has fewer stops and reads as a loop by mistake.
    private func loopStart(of chain: [Station]) -> Station? {
        guard StopInsertionPreview.isClosedLoop(chain, edges: vm.edgesByLine[group.id] ?? []) else { return nil }
        return chain.first
    }

    var body: some View {
        let numbers = stopNumbers
        return List {
            ForEach(chains, id: \.prefix) { chain in
                Section {
                    ForEach(chain.stations) { station in
                        StationCoordRow(station: station, number: numbers[station.id],
                                        showCoordinates: showCoordinates)
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
                } footer: {
                    if searchQuery.isEmpty, let start = loopStart(of: chain.stations) {
                        Label("Returns to \(start.name)", systemImage: "arrow.uturn.backward")
                            .font(.caption)
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
                lineEdges: vm.edgesByLine[group.id] ?? [],
                lastStopNumber: vm.lastStopNumberByLine[group.id]
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

// MARK: - Row

private struct StationCoordRow: View {
    let station: Station
    /// The stop's position in travel order. Nil when the stop has no place in a chain.
    let number: Int?
    let showCoordinates: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(station.name).font(.headline)
                if station.isInterchange {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(Color.ember)
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
