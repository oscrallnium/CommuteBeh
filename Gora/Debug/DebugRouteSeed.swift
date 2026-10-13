//
//  DebugRouteSeed.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/3/26.
//

#if DEBUG
import Foundation
import MapKit

/// Fills the commute search with a fixed origin and destination at launch, so a debug
/// run lands on the route being worked on instead of retyping both fields every build.
///
/// Off unless the scheme passes a launch argument, so an ordinary debug build behaves
/// exactly as before. Set it once in
/// **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Arguments Passed On Launch**:
///
/// - `-seedRoute` — fill and confirm both fields, then stop. Tap Search yourself.
/// - `-seedRouteSearch` — the same, and run the search too.
///
/// The queries are resolved through `MKLocalSearch` rather than stored as hardcoded
/// coordinates. That is the same lookup the suggestion list performs, so the seeded
/// state is identical to what tapping through the UI produces — including the rule that
/// an address landing within 150 m of a stop is confirmed as that stop instead. It also
/// means the seed keeps working if a place moves, and that changing the destination is
/// a matter of editing a string below rather than finding a latitude.
@MainActor
enum DebugRouteSeed {

    // Edit these two to seed a different trip.
    //
    // Verified against MKLocalSearch with the region below:
    //   "SM City Calamba" → SM City Calamba, Calamba      (14.203276, 121.154852)
    //   "Kuya Kubo"       → Kuya Kubo, Batong Malake,
    //                       Los Baños                     (14.169155, 121.238804)
    //
    // Leave "Kuya Kubo" unqualified. Spelling out the address —
    // "Kuya Kubo, Batong Malake, Los Baños, Laguna" — makes MKLocalSearch return the
    // *barangay* centroid instead of the restaurant, and "Kuya Kubo Los Banos" returns
    // the town. The bare name plus the region bias below is what lands on the place.
    static let originQuery = "SM City Calamba"
    static let destinationQuery = "Kuya Kubo"

    /// Metro Manila down through Laguna — wide enough to cover both queries above.
    /// `MKLocalSearch` ranks by distance from this region, so a tighter box gives more
    /// reliable hits for a name as generic as a carinderia's.
    private static let searchRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.40, longitude: 121.10),
        span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
    )

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-seedRoute") || runsSearch
    }

    static var runsSearch: Bool {
        ProcessInfo.processInfo.arguments.contains("-seedRouteSearch")
    }

    /// Resolves both queries and confirms them on the view model.
    ///
    /// Returns the label to display in each text field. The caller must assign these
    /// *after* this returns: the fields' `onChange` treats text that differs from the
    /// view model's confirmed label as a user edit and clears the resolved coordinate,
    /// so confirming first is what stops the seed from immediately invalidating itself.
    static func apply(to vm: RouteStore) async -> (origin: String?, destination: String?) {
        async let originResult = resolve(originQuery)
        async let destResult = resolve(destinationQuery)
        let (origin, destination) = await (originResult, destResult)

        if origin == nil {
            print("[DebugRouteSeed] no result for origin query '\(originQuery)'")
        }
        if destination == nil {
            print("[DebugRouteSeed] no result for destination query '\(destinationQuery)'")
        }

        return (
            origin.map { confirmOrigin($0, on: vm) },
            destination.map { confirmDestination($0, on: vm) }
        )
    }

    /// Runs the search, but only under `-seedRouteSearch`.
    ///
    /// The engine is built asynchronously from the view model's `init`, and
    /// `calculateRoute()` sets "Transit engine not ready." and bails if it is called
    /// first — so this waits for it rather than racing it.
    static func searchIfRequested(on vm: RouteStore) async {
        guard runsSearch else { return }

        var attempts = 0
        while !vm.isEngineReady && attempts < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        guard vm.isEngineReady else {
            print("[DebugRouteSeed] transit engine never became ready — skipping search")
            return
        }
        await vm.calculateRoute()
    }

    // MARK: Resolution

    private struct Place {
        let name: String
        let coordinate: Coordinates
    }

    private static func resolve(_ query: String) async -> Place? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = searchRegion

        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first
        else { return nil }

        let coord = item.placemark.coordinate
        return Place(
            name: item.name ?? query,
            coordinate: Coordinates(lat: coord.latitude, lng: coord.longitude)
        )
    }

    // MARK: Confirmation — mirrors `confirmOriginAddress` / `confirmDestinationAddress`

    private static func confirmOrigin(_ place: Place, on vm: RouteStore) -> String {
        if let station = vm.nearestStation(to: place.coordinate, within: 150) {
            vm.confirmOriginStation(station)
            return station.name
        }
        vm.originID = RouteRequest.virtualOriginID
        vm.originCoordinate = place.coordinate
        vm.confirmedOriginLabel = place.name
        vm.originSuggestions = []
        vm.showOriginSuggestions = false
        return place.name
    }

    private static func confirmDestination(_ place: Place, on vm: RouteStore) -> String {
        vm.destinationID = RouteRequest.virtualDestID
        vm.destinationCoordinate = place.coordinate
        vm.confirmedDestLabel = place.name
        vm.destSuggestions = []
        vm.showDestSuggestions = false
        return place.name
    }
}
#endif
