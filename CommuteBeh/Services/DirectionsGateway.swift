//
//  DirectionsGateway.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/31/26.
//

import Foundation
import MapKit
import OSLog

/// The single gate every MKDirections request in the app goes through.
///
/// Apple's GEO service rate-limits directions per app — Explore's own comment puts it at
/// roughly 50 per 60 s, and Explore's road-snapping pass can spend that in seconds. What
/// makes this worth centralising is *how* the limit reports itself: once exceeded, requests
/// come back as `MKError.directionsNotFound` — "Directions Not Available" — which is
/// indistinguishable from "there is genuinely no pedestrian path here".
///
/// Verified in the simulator: the SM City Calamba → Stop 1 walking request returns 437 m
/// when issued alone, and "Directions Not Available" for the identical coordinates seconds
/// later inside a burst, on the main actor and off it alike. Every walk leg silently losing
/// its geometry traces back to that.
///
/// So: one clock paces every caller, results are cached (in memory and on disk, since the
/// same origin/stop pairs recur across searches), and user-facing work is paced tighter than
/// background decoration so Explore can never starve a search the user is waiting on.
actor DirectionsGateway {
    static let shared = DirectionsGateway()

    struct Path: Codable, Sendable {
        let minutes: Double
        let distanceKm: Double
        let coordinates: [Coordinates]
    }

    /// How closely a caller may space its requests on the shared clock.
    enum Urgency {
        /// A route the user is looking at right now — a search needs one or two of these.
        case interactive
        /// Map decoration that can take its time (Explore's snapping pass).
        case background

        var spacing: Duration {
            switch self {
            case .interactive: .milliseconds(300)
            case .background:  .milliseconds(1200)   // ≈50/min sustained, the documented ceiling
            }
        }
    }

    private var cache: [String: Path] = [:]
    /// Insertion order, for eviction — Explore alone can push hundreds of segments through.
    private var keyOrder: [String] = []
    private let maxEntries = 600
    private var didLoadDisk = false
    /// Earliest instant the next request may start. Reserved synchronously (before any
    /// `await`), so concurrent callers each take a distinct slot instead of all firing now.
    private var nextSlot = Date.distantPast
    private let requestTimeout: Duration = .seconds(8)

    /// Directions between two points, or `nil` if MapKit couldn't supply them.
    /// Never returns a straight line — callers must handle `nil` by drawing nothing.
    func path(
        from: Coordinates,
        to: Coordinates,
        transport: MKDirectionsTransportType,
        urgency: Urgency
    ) async -> Path? {
        loadDiskCacheIfNeeded()

        let key = Self.key(from: from, to: to, transport: transport)
        if let hit = cache[key] { return hit }

        await waitForSlot(urgency)

        guard let path = await Self.request(from: from, to: to, transport: transport,
                                            timeout: requestTimeout) else { return nil }
        store(path, for: key)
        return path
    }

    // MARK: Pacing

    private func waitForSlot(_ urgency: Urgency) async {
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(urgency.spacing.asSeconds)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    // MARK: Cache

    private func store(_ path: Path, for key: String) {
        if cache[key] == nil { keyOrder.append(key) }
        cache[key] = path
        while keyOrder.count > maxEntries {
            cache.removeValue(forKey: keyOrder.removeFirst())
        }
        saveDiskCache()
    }

    private static func key(from: Coordinates, to: Coordinates, transport: MKDirectionsTransportType) -> String {
        // 5 dp ≈ 1 m: precise enough that two different stops never collide, coarse enough
        // that the same stop resolved twice hits the cache.
        String(format: "%d|%.5f,%.5f>%.5f,%.5f",
               transport.rawValue, from.lat, from.lng, to.lat, to.lng)
    }

    private static var diskURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("directions-cache.json")
    }

    private func loadDiskCacheIfNeeded() {
        guard !didLoadDisk else { return }
        didLoadDisk = true
        guard let url = Self.diskURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Path].self, from: data) else { return }
        cache = stored
        keyOrder = Array(stored.keys)
    }

    private func saveDiskCache() {
        guard let url = Self.diskURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Request

    /// One attempt, raced against `timeout` so a hanging request never blocks the clock
    /// (same pattern as `LoopCreatorView.fetchRoadRoute`).
    private static func request(
        from: Coordinates,
        to: Coordinates,
        transport: MKDirectionsTransportType,
        timeout: Duration
    ) async -> Path? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.lat, longitude: from.lng),
                                   address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.lat, longitude: to.lng),
                                        address: nil)
        request.transportType = transport

        return await withTaskGroup(of: Path?.self) { group in
            group.addTask {
                let response: MKDirections.Response
                do {
                    response = try await MKDirections(request: request).calculate()
                } catch {
                    // Logged by name: "Directions Not Available" under load is the rate
                    // limiter, not a missing path, and only the former is worth retrying.
                    directionsLog.error("\(transport.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                guard let route = response.routes.first, route.polyline.pointCount > 0 else { return nil }
                let count = route.polyline.pointCount
                var coords = Array(repeating: CLLocationCoordinate2D(), count: count)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                return Path(
                    minutes: route.expectedTravelTime / 60,
                    distanceKm: route.distance / 1000,
                    coordinates: coords.map { Coordinates(lat: $0.latitude, lng: $0.longitude) }
                )
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

nonisolated private extension Duration {
    /// Seconds as a Double — for interop with `Date` arithmetic.
    var asSeconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}

nonisolated private extension MKDirectionsTransportType {
    var label: String { self == .walking ? "walking" : "driving" }
}
