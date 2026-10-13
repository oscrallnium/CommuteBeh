//
//  AddPlaceViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import CoreLocation
import Foundation
import MapKit

/// Form state for the Add Place sheet. See `Commute-Cards.md`.
@Observable
@MainActor
final class AddPlaceViewModel {

    /// The location the passenger picked, and which control picked it.
    struct PickedLocation: Equatable {
        enum Source { case search, current }
        let coordinates: Coordinates
        let label: String
        let stationId: StationID?
        let source: Source
    }

    var name = ""
    var icon: SavedPlaceIcon = .mappin
    var query = ""
    private(set) var suggestions: [LocationSuggestion] = []
    private(set) var picked: PickedLocation?
    private(set) var isResolving = false
    private(set) var currentAddress: String?

    let userLocation: Coordinates?
    /// The place the sheet edits, or nil when the sheet adds a new place.
    let editing: SavedPlace?

    private let stations: [Station]
    private let search = AddressSearchService()
    private var debounce: Task<Void, Never>?
    private var programmaticQuery: String?
    private var pickToken = 0

    init(stations: [Station], userLocation: Coordinates?, editing: SavedPlace? = nil) {
        self.stations = stations
        self.userLocation = userLocation
        self.editing = editing
        if let editing {
            name = editing.name
            icon = editing.icon
            query = editing.addressLabel
            picked = PickedLocation(coordinates: editing.coordinates, label: editing.addressLabel,
                                    stationId: editing.stationId, source: .search)
        }
        search.onUpdate = { [weak self] in self?.mergeSuggestions() }
    }

    var canSave: Bool {
        picked != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Subtitle of the Use Current Location row: the address, or the coordinates when
    /// reverse geocoding fails, or a notice when there is no fix.
    var currentLocationSubtitle: String {
        if let currentAddress { return currentAddress }
        guard let userLocation else { return "Location unavailable" }
        return Self.coordinateText(userLocation)
    }

    // MARK: Address search

    /// Called when the address field text changes. Typing invalidates the picked location.
    func queryChanged(_ text: String) {
        if text == programmaticQuery { return }
        programmaticQuery = nil
        picked = nil
        debounce?.cancel()
        guard !text.isEmpty else {
            suggestions = []
            search.cancel()
            return
        }
        mergeSuggestions()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.query == text else { return }
            self.search.update(fragment: text)
        }
    }

    func pick(_ suggestion: LocationSuggestion) {
        switch suggestion {
        case .station(let station):
            setPicked(.init(coordinates: station.coordinates, label: station.name,
                            stationId: station.id, source: .search))
        case .address(let completion):
            pickToken += 1
            let token = pickToken
            isResolving = true
            Task {
                let coordinates = await search.resolve(completion)
                guard token == pickToken else { return }
                isResolving = false
                guard let coordinates else { return }
                setPicked(.init(coordinates: coordinates, label: completion.title,
                                stationId: nil, source: .search))
            }
        }
    }

    func useCurrentLocation() {
        guard let userLocation else { return }
        setPicked(.init(coordinates: userLocation, label: currentLocationSubtitle,
                        stationId: nil, source: .current), queryText: "")
    }

    // MARK: Current address

    func loadCurrentAddress() async {
        guard let userLocation else { return }
        let location = CLLocation(latitude: userLocation.lat, longitude: userLocation.lng)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        let items = await withCheckedContinuation { (cont: CheckedContinuation<[MKMapItem], Never>) in
            request.getMapItems { items, _ in cont.resume(returning: items ?? []) }
        }
        guard let item = items.first else { return }
        currentAddress = item.address?.shortAddress ?? item.address?.fullAddress
    }

    // MARK: Save

    func makePlace() -> SavedPlace? {
        guard canSave, let picked else { return nil }
        let now = Date()
        return SavedPlace(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            addressLabel: picked.label,
            coordinates: picked.coordinates,
            stationId: picked.stationId,
            createdAt: editing?.createdAt ?? now,
            updatedAt: now
        )
    }

    // MARK: Helpers

    private func setPicked(_ location: PickedLocation, queryText: String? = nil) {
        debounce?.cancel()
        search.cancel()
        let text = queryText ?? location.label
        programmaticQuery = text
        query = text
        suggestions = []
        picked = location
    }

    private func mergeSuggestions() {
        guard !query.isEmpty else { return }
        let q = query.lowercased()
        let stationMatches = stations.filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
        let stationNames = Set(stationMatches.map { $0.name.lowercased() })
        let addressMatches = search.completions.filter {
            !($0.subtitle.isEmpty && stationNames.contains($0.title.lowercased()))
        }
        suggestions = stationMatches.prefix(5).map(LocationSuggestion.station)
            + addressMatches.prefix(5).map(LocationSuggestion.address)
    }

    private static func coordinateText(_ coordinates: Coordinates) -> String {
        String(format: "%.5f, %.5f", coordinates.lat, coordinates.lng)
    }
}
