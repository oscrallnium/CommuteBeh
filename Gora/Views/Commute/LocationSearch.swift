//
//  LocationSearch.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/19/26.
//

import CoreLocation
import Foundation
import MapKit

// MARK: - LocationSuggestion

/// A single row in the origin/destination suggestion list — either a routable transit
/// station or a live MapKit type-ahead completion. Completions carry no coordinate; it is
/// resolved only when the user taps the row (see `AddressSearchService.resolve`).
enum LocationSuggestion: Identifiable {
    case station(Station)
    case address(MKLocalSearchCompletion)

    var id: String {
        switch self {
        case .station(let s): s.id
        case .address(let c): "addr_\(c.title)_\(c.subtitle)"
        }
    }
}

// MARK: - AddressSearchService

/// Wraps `MKLocalSearchCompleter` (type-ahead suggestions) and `MKLocalSearch` (tap-time
/// coordinate resolution) behind a plain callback surface. One instance per search field
/// avoids cross-talk between simultaneous origin/destination queries.
final class AddressSearchService: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()

    /// Latest completions for the current fragment; cleared on failure.
    private(set) var completions: [MKLocalSearchCompletion] = []

    /// Called whenever `completions` changes — the ViewModel re-merges with station matches.
    var onUpdate: (() -> Void)?

    /// Luzon, the only area the search field offers results from: the mainland plus Mindoro,
    /// Marinduque and Catanduanes. Do not derive this from station coordinates — searching must
    /// stay wider than the network, or new areas are unsearchable before a stop can exist.
    private static let searchableRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 15.55, longitude: 122.0),
        span: MKCoordinateSpan(latitudeDelta: 6.5, longitudeDelta: 4.8)
    )

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.searchableRegion
        // `region` on its own is only a hint — MapKit still returns a Jakarta or a Kuala
        // Lumpur when the fragment matches better there, which is what put foreign places
        // in the list. `.required` turns the same rectangle into a filter.
        completer.regionPriority = .required
    }

    func update(fragment: String) {
        completer.queryFragment = fragment
    }

    func cancel() {
        completer.cancel()
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
        onUpdate?()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
        onUpdate?()
    }

    /// Phase 2: resolves a tapped completion to a coordinate with a one-shot search.
    func resolve(_ completion: MKLocalSearchCompletion) async -> Coordinates? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return nil }
        return Coordinates(lat: item.placemark.coordinate.latitude,
                            lng: item.placemark.coordinate.longitude)
    }
}

// MARK: - CommuteViewModel + Address Search

/// Address-search half of the search field state machine. Kept in its own file/extension so
/// `TransportMode.swift` (the domain layer) never needs to import MapKit.
/// See FEATURE_ADDRESS_ROUTING_FINDINGS.md §3–§4 for the design this implements.
extension RouteStore {

    // MARK: Origin

    /// Called from `ContentView`'s `onChange(of: originText)`. Filters stations synchronously
    /// and kicks off a debounced `MKLocalSearchCompleter` fragment update for addresses.
    func updateOriginSuggestions(_ query: String) {
        // Programmatic echo (selection/pin/swap just set originText) — leave the list exactly
        // as the confirm path left it; do not re-open it.
        if invalidateOriginIfEdited(query) { return }
        lastOriginQuery = query
        originDebounce?.cancel()

        guard !query.isEmpty else {
            originSuggestions = []
            showOriginSuggestions = false
            return
        }

        remergeOriginSuggestions()
        showOriginSuggestions = true
        showDestSuggestions = false

        originDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.lastOriginQuery == query else { return }
            self.addressSearchOrigin.update(fragment: query)
        }
    }

    /// Confirms a station tap: routable immediately, no coordinate needed.
    func confirmOriginStation(_ station: Station) {
        originDebounce?.cancel()
        originID = station.id
        originCoordinate = nil
        confirmedOriginLabel = station.name
        originSuggestions = []
        showOriginSuggestions = false
    }

    /// Confirms an address tap by resolving the completion to a coordinate over the network.
    /// Returns the display name for the field, or `nil` when resolution fails or goes stale.
    /// On `nil` the caller leaves the text field and the suggestion list untouched.
    @MainActor
    func confirmOriginAddress(_ completion: MKLocalSearchCompletion) async -> String? {
        isResolvingOrigin = true
        let fragmentAtTap = lastOriginQuery
        defer { isResolvingOrigin = false }

        guard let coord = await addressSearchOrigin.resolve(completion) else { return nil }
        guard lastOriginQuery == fragmentAtTap else { return nil } // user kept typing — stale

        originSuggestions = []
        showOriginSuggestions = false

        // R6: an address that resolves onto (or right next to) a real station is confirmed
        // as that station — it routes directly with no access-walk penalty and avoids a
        // duplicate-looking entry.
        if let match = nearestStation(to: coord, within: 150) {
            originID = match.id
            originCoordinate = nil
            confirmedOriginLabel = match.name
            return match.name
        }

        originID = RouteRequest.virtualOriginID
        originCoordinate = coord
        confirmedOriginLabel = completion.title
        // R4: warn immediately if this address is beyond walking range of any stop, rather
        // than waiting for the eventual failed search.
        if let nearest = nearestStationInfo(coord), nearest.km > AccessPolicy.hardCeilingKm {
            errorMessage = "This start point isn't served yet — the nearest stop (\(nearest.name)) is \(distanceLabel(nearest.km)) away."
        }
        return completion.title
    }

    // MARK: Destination

    func updateDestSuggestions(_ query: String) {
        if invalidateDestIfEdited(query) { return }
        lastDestQuery = query
        destDebounce?.cancel()

        guard !query.isEmpty else {
            destSuggestions = []
            showDestSuggestions = false
            return
        }

        remergeDestSuggestions()
        showDestSuggestions = true
        showOriginSuggestions = false

        destDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.lastDestQuery == query else { return }
            self.addressSearchDest.update(fragment: query)
        }
    }

    func confirmDestinationStation(_ station: Station) {
        destDebounce?.cancel()
        destinationID = station.id
        destinationCoordinate = nil
        confirmedDestLabel = station.name
        destSuggestions = []
        showDestSuggestions = false
    }

    @MainActor
    func confirmDestinationAddress(_ completion: MKLocalSearchCompletion) async -> String? {
        isResolvingDestination = true
        let fragmentAtTap = lastDestQuery
        defer { isResolvingDestination = false }

        guard let coord = await addressSearchDest.resolve(completion) else { return nil }
        guard lastDestQuery == fragmentAtTap else { return nil }

        destSuggestions = []
        showDestSuggestions = false

        if let match = nearestStation(to: coord, within: 150) {
            destinationID = match.id
            destinationCoordinate = nil
            confirmedDestLabel = match.name
            return match.name
        }

        destinationID = RouteRequest.virtualDestID
        destinationCoordinate = coord
        confirmedDestLabel = completion.title
        if let nearest = nearestStationInfo(coord), nearest.km > AccessPolicy.hardCeilingKm {
            errorMessage = "This destination isn't served yet — the nearest stop (\(nearest.name)) is \(distanceLabel(nearest.km)) away."
        }
        return completion.title
    }

    // MARK: Invalidation (fixes R1/R2/R3 — see FEATURE_ADDRESS_ROUTING_FINDINGS.md §4–§5)

    /// Clears `originID` and `originCoordinate` when `query` diverges from the last confirmed
    /// selection, so `findRoute` cannot build access edges into a location the field no longer
    /// shows. Returns `true` for a programmatic echo, and the caller must then return at once.
    private func invalidateOriginIfEdited(_ query: String) -> Bool {
        if confirmedOriginLabel == query { return true }
        confirmedOriginLabel = nil
        originID = ""
        originCoordinate = nil
        return false
    }

    /// Returns `true` when this was a programmatic echo — callers must return immediately.
    private func invalidateDestIfEdited(_ query: String) -> Bool {
        if confirmedDestLabel == query { return true }
        confirmedDestLabel = nil
        destinationID = ""
        destinationCoordinate = nil
        return false
    }

    // MARK: Merging — stations first, then up to 5 address completions, text-level dedupe

    func remergeOriginSuggestions() {
        guard !lastOriginQuery.isEmpty else { return }
        let q = lastOriginQuery.lowercased()
        let stationMatches = allStations.filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
        let stationNames = Set(stationMatches.map { $0.name.lowercased() })
        let addressMatches = addressSearchOrigin.completions.filter {
            !($0.subtitle.isEmpty && stationNames.contains($0.title.lowercased()))
        }
        originSuggestions =
            stationMatches.map(LocationSuggestion.station) +
            addressMatches.prefix(5).map(LocationSuggestion.address)
    }

    func remergeDestSuggestions() {
        guard !lastDestQuery.isEmpty else { return }
        let q = lastDestQuery.lowercased()
        let stationMatches = allStations.filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
        let stationNames = Set(stationMatches.map { $0.name.lowercased() })
        let addressMatches = addressSearchDest.completions.filter {
            !($0.subtitle.isEmpty && stationNames.contains($0.title.lowercased()))
        }
        destSuggestions =
            stationMatches.map(LocationSuggestion.station) +
            addressMatches.prefix(5).map(LocationSuggestion.address)
    }

    // MARK: R4/R6 — nearest-station lookups (Haversine via CLLocation)

    /// Nearest station to `coord` if within `meters` — used to silently confirm an address
    /// that resolves onto (or very near) an existing station as that station instead (R6).
    func nearestStation(to coord: Coordinates, within meters: Double) -> Station? {
        let loc = CLLocation(latitude: coord.lat, longitude: coord.lng)
        return allStations
            .map { ($0, loc.distance(from: CLLocation(latitude: $0.coordinates.lat, longitude: $0.coordinates.lng))) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Distance in km from `coord` to the nearest station — used for the R4 out-of-range warning.
    func nearestStationDistanceKm(_ coord: Coordinates) -> Double? {
        nearestStationInfo(coord)?.km
    }

    /// Nearest station's name and distance in km — the warning names the stop so the user
    /// can judge whether it's worth the walk, matching `RouteError.originTooFar`'s wording.
    func nearestStationInfo(_ coord: Coordinates) -> (name: String, km: Double)? {
        let loc = CLLocation(latitude: coord.lat, longitude: coord.lng)
        return allStations
            .map { (name: $0.name,
                    km: loc.distance(from: CLLocation(latitude: $0.coordinates.lat,
                                                      longitude: $0.coordinates.lng)) / 1000) }
            .min { $0.km < $1.km }
    }
}
