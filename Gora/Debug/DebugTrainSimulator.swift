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
/// Commute Mode's live-tracking features can be exercised without riding an actual
/// train. See `Debug.md`.
@MainActor
@Observable
final class DebugTrainSimulator {

    // Real station IDs from the graph, not coordinates — resolved through
    // `RouteStore.allStations` at run time, so a station rename never leaves this
    // pointing at nothing.
    static let originStationID: StationID = "MRT_NORTH_AVE"
    static let destinationStationID: StationID = "MRT_GUADALUPE"

    /// Simulated ground speed — MRT-3's approximate running speed between stations.
    static let speedKmh: Double = 60
    private static let speedMetersPerSecond: Double = speedKmh / 3.6
    private static let tickInterval: TimeInterval = 1.0
    /// Seconds the train waits at each intermediate station.
    static let dwellSeconds: TimeInterval = 10

    /// True while a run is being prepared. Blocks a second start.
    private(set) var isStarting = false
    /// True from the moment the run owns the passenger position until `stop` runs.
    private(set) var isActive = false
    var isBusy: Bool { isStarting || isActive }
    /// Set on a failed resolve/route/geometry step, cleared at the start of the next run.
    private(set) var lastError: String?

    private var route: [CLLocationCoordinate2D] = []
    private var cumulativeMeters: [CLLocationDistance] = []
    private var dwellMeters: [CLLocationDistance] = []
    private var nextDwellIndex = 0
    private var dwellRemaining: TimeInterval = 0
    private var distanceTraveled: CLLocationDistance = 0
    private var tickTask: Task<Void, Never>?

    /// Resolves both stations, calculates the route, and hands the chosen option back
    /// via `onRouteReady`. The caller starts Commute Mode with it and can await camera
    /// setup. The passenger already sits at the origin when `onRouteReady` runs.
    func start(routeStore: RouteStore, onRouteReady: (RouteOption) async -> Void) async {
        guard !isBusy else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil

        guard let origin = routeStore.allStations.first(where: { $0.id == Self.originStationID }),
              let destination = routeStore.allStations.first(where: { $0.id == Self.destinationStationID })
        else {
            fail("Could not find North Ave / Guadalupe in the loaded graph.")
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
            fail("Transit engine never became ready.")
            return
        }

        await routeStore.calculateRoute()
        guard let option = routeStore.routeOptions.first(where: { $0.result.legs.first?.fromStation.id == origin.id })
        else {
            fail(routeStore.errorMessage ?? "No route from North Ave to Guadalupe.")
            return
        }

        let flattened = Self.flattenedPolyline(option.result)
        guard flattened.count >= 2 else {
            fail("Route has no drawable geometry.")
            return
        }
        route = flattened
        cumulativeMeters = Self.cumulativeDistances(flattened)
        dwellMeters = Self.dwellDistances(option.result, route: flattened, cumulativeMeters: cumulativeMeters)
        nextDwellIndex = 0
        dwellRemaining = 0
        distanceTraveled = 0

        isActive = true
        routeStore.beginSimulatedLocation(at: Coordinates(lat: flattened[0].latitude, lng: flattened[0].longitude))
        await onRouteReady(option)
        guard isActive else { return }
        beginTicking(routeStore: routeStore)
    }

    /// Ends the run and hands the passenger position back to real GPS. Does not end
    /// Commute Mode — `ContentView.endCommute()` calls this.
    func stop(routeStore: RouteStore) {
        isActive = false
        tickTask?.cancel()
        tickTask = nil
        route = []
        cumulativeMeters = []
        dwellMeters = []
        routeStore.endSimulatedLocation()
    }

    private func fail(_ message: String) {
        lastError = message
        print("[DebugSim] \(message)")
    }

    private func beginTicking(routeStore: RouteStore) {
        var isFirstTick = true
        tickTask = Task { [weak self, weak routeStore] in
            while let self, let routeStore, self.isActive, !Task.isCancelled {
                self.advance(routeStore: routeStore, movesForward: !isFirstTick)
                isFirstTick = false
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
    }

    private func advance(routeStore: RouteStore, movesForward: Bool) {
        let total = cumulativeMeters.last ?? 0
        var speed = Self.speedMetersPerSecond
        if dwellRemaining > 0 {
            dwellRemaining -= Self.tickInterval
            speed = 0
        } else if movesForward {
            let next = min(total, distanceTraveled + Self.speedMetersPerSecond * Self.tickInterval)
            if nextDwellIndex < dwellMeters.count, next >= dwellMeters[nextDwellIndex] {
                distanceTraveled = dwellMeters[nextDwellIndex]
                nextDwellIndex += 1
                dwellRemaining = Self.dwellSeconds
                speed = 0
            } else {
                distanceTraveled = next
            }
        }
        let arrived = distanceTraveled >= total
        if arrived { speed = 0 }

        guard let coordinate = Self.coordinate(at: distanceTraveled, route: route, cumulativeMeters: cumulativeMeters)
        else { return }
        routeStore.applySimulatedFix(
            Coordinates(lat: coordinate.latitude, lng: coordinate.longitude),
            speed: speed,
            course: Self.bearing(at: distanceTraveled, route: route, cumulativeMeters: cumulativeMeters)
        )
        if arrived { tickTask?.cancel() }
    }

    // MARK: Geometry
    //
    // "Flatten, accumulate distance, interpolate" — see `Debug.md`.

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

    /// Route distance of each intermediate station, in travel order. A station maps to the
    /// nearest route point at or after the previous one.
    private static func dwellDistances(
        _ result: RouteResult, route: [CLLocationCoordinate2D], cumulativeMeters: [CLLocationDistance]
    ) -> [CLLocationDistance] {
        var distances: [CLLocationDistance] = []
        var searchFrom = 0
        for station in result.legs.flatMap({ Array($0.stops.dropFirst().dropLast()) }) {
            let target = CLLocation(latitude: station.coordinates.lat, longitude: station.coordinates.lng)
            let candidates = route.indices.dropFirst(searchFrom)
            guard let nearest = candidates.min(by: {
                CLLocation(latitude: route[$0].latitude, longitude: route[$0].longitude).distance(from: target)
                    < CLLocation(latitude: route[$1].latitude, longitude: route[$1].longitude).distance(from: target)
            }) else { continue }
            searchFrom = nearest
            distances.append(cumulativeMeters[nearest])
        }
        return distances
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
