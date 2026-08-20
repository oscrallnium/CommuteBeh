//
//  DebugTrainSimulator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/17/26.
//

#if DEBUG
import CoreLocation
import Foundation

/// Drives a simulated ride along a fixed route (MRT North Avenue → Guadalupe) so
/// Commute Mode's live-tracking features — track snapping, camera follow, the
/// ahead-only polyline trim — can be exercised without riding an actual train.
///
/// Feeds `RouteStore.userLocation` directly, the same property CoreLocation writes
/// to, so every downstream consumer sees an identical shape of update. Real GPS is
/// not read while a run is active — see `RouteStore.isLocationSimulated`.
@MainActor
@Observable
final class DebugTrainSimulator {

    // Real station IDs from the graph, not coordinates — resolved through
    // `RouteStore.allStations` at run time, so a station rename never leaves this
    // pointing at nothing.
    static let originStationID: StationID = "MRT_NORTH_AVE"
    static let destinationStationID: StationID = "MRT_GUADALUPE"

    /// Simulated ground speed — MRT-3's approximate running speed between stations.
    /// Dwell time at intermediate stops is not modelled, so a full run finishes
    /// faster than a real ride does.
    static let speedKmh: Double = 60
    private static let speedMetersPerSecond: Double = speedKmh / 3.6
    private static let tickInterval: TimeInterval = 1.0

    private(set) var isRunning = false
    /// Set on a failed resolve/route/geometry step, cleared at the start of the next run.
    private(set) var lastError: String?

    private var route: [CLLocationCoordinate2D] = []
    private var cumulativeMeters: [CLLocationDistance] = []
    private var distanceTraveled: CLLocationDistance = 0
    private var tickTask: Task<Void, Never>?

    /// Resolves both stations, calculates the route, and hands the chosen option back
    /// via `onRouteReady` — the caller starts Commute Mode with it exactly as if a
    /// route card had been tapped. Movement begins only after that call returns.
    func start(routeStore: RouteStore, onRouteReady: (RouteOption) -> Void) async {
        guard !isRunning else { return }
        lastError = nil

        guard let origin = routeStore.allStations.first(where: { $0.id == Self.originStationID }),
              let destination = routeStore.allStations.first(where: { $0.id == Self.destinationStationID })
        else {
            lastError = "Could not find North Ave / Guadalupe in the loaded graph."
            return
        }

        routeStore.confirmOriginStation(origin)
        routeStore.confirmDestinationStation(destination)

        var attempts = 0
        while !routeStore.isEngineReady, attempts < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        guard routeStore.isEngineReady else {
            lastError = "Transit engine never became ready."
            return
        }

        await routeStore.calculateRoute()
        guard let option = routeStore.routeOptions.first else {
            lastError = routeStore.errorMessage ?? "No route returned for North Ave → Guadalupe."
            return
        }

        let flattened = Self.flattenedPolyline(option.result)
        guard flattened.count >= 2 else {
            lastError = "Route has no drawable geometry."
            return
        }
        route = flattened
        cumulativeMeters = Self.cumulativeDistances(flattened)
        distanceTraveled = 0

        routeStore.isLocationSimulated = true
        onRouteReady(option)
        beginTicking(routeStore: routeStore)
    }

    /// Stops the run and hands GPS back to CoreLocation. Does not end Commute Mode —
    /// the caller does that the same way it would for a real ride.
    func stop(routeStore: RouteStore) {
        isRunning = false
        tickTask?.cancel()
        tickTask = nil
        routeStore.isLocationSimulated = false
    }

    private func beginTicking(routeStore: RouteStore) {
        isRunning = true
        tickTask = Task { [weak self, weak routeStore] in
            while let self, let routeStore, self.isRunning, !Task.isCancelled {
                self.advance(routeStore: routeStore)
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    private func advance(routeStore: RouteStore) {
        let total = cumulativeMeters.last ?? 0
        distanceTraveled = min(total, distanceTraveled + Self.speedMetersPerSecond * Self.tickInterval)

        guard let coordinate = Self.coordinate(at: distanceTraveled, route: route, cumulativeMeters: cumulativeMeters)
        else { return }

        routeStore.userLocation = Coordinates(lat: coordinate.latitude, lng: coordinate.longitude)
        routeStore.userSpeed = Self.speedMetersPerSecond
        routeStore.userCourse = Self.bearing(at: distanceTraveled, route: route, cumulativeMeters: cumulativeMeters)

        if distanceTraveled >= total {
            isRunning = false
            tickTask?.cancel()
        }
    }

    // MARK: Geometry
    //
    // Mirrors `CommuteProgressEngine.LegGeometry` and `TrackSnapper.LineGeometry`'s
    // "flatten, accumulate distance, interpolate" shape — a fourth copy of that
    // pattern reads better here than threading a debug-only concern through either
    // of those actor-isolated types.

    /// Every leg's polyline concatenated in order, dropping each subsequent leg's
    /// first point — it duplicates the previous leg's last point, the shared station.
    private static func flattenedPolyline(_ result: RouteResult) -> [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = []
        for (index, leg) in result.legs.enumerated() {
            let legPoints = leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            points.append(contentsOf: index == 0 ? legPoints : Array(legPoints.dropFirst()))
        }
        return points
    }

    private static func cumulativeDistances(_ coords: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        guard coords.count >= 2 else { return coords.isEmpty ? [] : [0] }
        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(coords.count)
        for i in 1..<coords.count {
            let segment = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
            cumulative.append(cumulative[i - 1] + segment)
        }
        return cumulative
    }

    private static func coordinate(
        at meters: CLLocationDistance, route: [CLLocationCoordinate2D], cumulativeMeters: [CLLocationDistance]
    ) -> CLLocationCoordinate2D? {
        guard route.count >= 2 else { return route.first }
        let clamped = max(0, min(cumulativeMeters.last ?? 0, meters))
        for i in 0..<(cumulativeMeters.count - 1) {
            guard clamped <= cumulativeMeters[i + 1] else { continue }
            let span = cumulativeMeters[i + 1] - cumulativeMeters[i]
            let t = span > 0 ? (clamped - cumulativeMeters[i]) / span : 0
            let a = route[i], b = route[i + 1]
            return CLLocationCoordinate2D(latitude: a.latitude + t * (b.latitude - a.latitude),
                                           longitude: a.longitude + t * (b.longitude - a.longitude))
        }
        return route.last
    }

    /// True-north bearing of the segment the simulated position currently sits on —
    /// fed to `userCourse` so the 3D camera has a heading to follow, the same as it
    /// would from a real fix's course.
    private static func bearing(
        at meters: CLLocationDistance, route: [CLLocationCoordinate2D], cumulativeMeters: [CLLocationDistance]
    ) -> CLLocationDirection? {
        guard route.count >= 2 else { return nil }
        let clamped = max(0, min(cumulativeMeters.last ?? 0, meters))
        for i in 0..<(cumulativeMeters.count - 1) {
            guard clamped <= cumulativeMeters[i + 1] else { continue }
            let a = route[i], b = route[i + 1]
            let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
            let deltaLng = (b.longitude - a.longitude) * .pi / 180
            let y = sin(deltaLng) * cos(lat2)
            let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLng)
            let degrees = atan2(y, x) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
        return nil
    }
}
#endif
