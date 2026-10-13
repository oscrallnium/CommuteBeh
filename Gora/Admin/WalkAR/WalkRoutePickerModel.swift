//
//  WalkRoutePickerModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import CoreLocation
import MapKit
import Observation

/// Holds the destination pin and the walking route to it for the walk AR test.
@Observable
final class WalkRoutePickerModel {
    struct Route {
        let polyline: [Coordinates]
        let distanceMeters: Double
        let minutes: Double
    }

    private(set) var userCoordinate: Coordinates?
    private(set) var destination: Coordinates?
    private(set) var route: Route?
    private(set) var isLoading = false
    private(set) var message: String?

    @ObservationIgnored private let location = WalkARLocationService()
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    init() {
        location.onFix = { [weak self] fix in
            guard fix.horizontalAccuracy >= 0 else { return }
            self?.userCoordinate = Coordinates(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude)
        }
        location.onDenied = { [weak self] in self?.message = "Location access is off. Turn it on in Settings." }
    }

    func start() { location.start() }

    func stop() {
        location.stop()
        routeTask?.cancel()
    }

    /// Drops the pin and requests a walking route from the current location.
    func setDestination(_ coordinate: Coordinates) {
        destination = coordinate
        route = nil
        message = nil
        routeTask?.cancel()
        guard let userCoordinate else {
            message = "Waiting for your location"
            return
        }
        isLoading = true
        routeTask = Task { [weak self] in
            let result = await Self.walkingRoute(from: userCoordinate, to: coordinate)
            guard !Task.isCancelled, let self else { return }
            self.isLoading = false
            self.route = result
            if result == nil { self.message = "No walking route found" }
        }
    }

    private static func walkingRoute(from: Coordinates, to: Coordinates) async -> Route? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.lat, longitude: from.lng), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.lat, longitude: to.lng), address: nil)
        request.transportType = .walking
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first, route.polyline.pointCount > 1 else { return nil }
        var points = Array(repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
        route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
        return Route(polyline: points.map { Coordinates(lat: $0.latitude, lng: $0.longitude) },
                     distanceMeters: route.distance, minutes: route.expectedTravelTime / 60)
    }
}
