//
//  CommuteMapOverlays.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import MapKit

// MARK: - Passenger Puck

/// Content for the passenger's `UserAnnotation`. MapKit owns the position; this supplies the
/// orange look and one behaviour — an idle breathe while the passenger stands still, which
/// stops as soon as `speed` reports movement.
struct PassengerPuck: View {
    /// `userLocation.location?.speed`, handed down by the `UserAnnotation` closure. `nil`
    /// before MapKit has a fix.
    let speed: CLLocationSpeed?

    @State private var isStill = true
    /// Debounced target for `isStill` — see the `.task(id:)` below. Kept separate so a
    /// single noisy sample crossing the threshold can't flip the pulse on its own.
    @State private var pendingStill = true
    @State private var breathe = false

    /// Below this, the passenger reads as stopped rather than mid-stride — comfortably
    /// under even a slow walk (~1.2 m/s), so nothing anyone would call moving triggers it.
    private static let stillThreshold: CLLocationSpeed = 0.4
    /// How long a speed reading must hold before the pulse commits to it. Long enough that a
    /// sample hovering near the threshold does not flicker the halo on and off.
    private static let debounce = Duration.milliseconds(700)

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Colors.action.opacity(isStill && breathe ? 0.32 : 0.20))
                .frame(width: 34, height: 34)
                .scaleEffect(isStill && breathe ? 1.25 : 1.0)
            Circle()
                .fill(DesignTokens.Colors.action)
                .frame(width: 16, height: 16)
            Circle()
                .stroke(.white, lineWidth: 2.5)
                .frame(width: 16, height: 16)
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
        .onChange(of: speed, initial: true) { _, newSpeed in
            pendingStill = Self.isBelowThreshold(newSpeed)
        }
        // Auto-cancelled and restarted by SwiftUI on every `pendingStill` change, which is
        // what makes this a debounce rather than a delay: a classification that flips back
        // before `debounce` elapses just restarts the wait instead of committing.
        .task(id: pendingStill) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isStill = pendingStill
        }
        .onChange(of: isStill, initial: true) { _, still in
            if still {
                withAnimation(DesignTokens.Motion.locationPulse) { breathe = true }
            } else {
                // A plain assignment, not `withAnimation`. `isStill` already masks `breathe`,
                // so the halo is at rest and this only resets the value for the next animation.
                breathe = false
            }
        }
    }

    private static func isBelowThreshold(_ speed: CLLocationSpeed?) -> Bool {
        // No reliable reading — no fix yet, or CoreLocation's "invalid" sentinel — reads
        // as still. There's no evidence of movement to justify treating it otherwise.
        guard let speed, speed >= 0 else { return true }
        return speed < stillThreshold
    }
}

// MARK: - Route Geometry

/// Map-ready coordinates for one `RouteResult`: the polyline per leg, plus the bounding box
/// of every polyline and its endpoints. Computed once per route, because refined walk legs
/// hold hundreds of points and `ContentView.body` re-evaluates on every animation frame.
struct RouteGeometry {
    /// Keyed by `RouteLeg.id`. A leg MKDirections couldn't route maps to an empty array —
    /// it draws nothing on purpose; never fall back to connecting its endpoints.
    let polylines: [RouteLeg.ID: [CLLocationCoordinate2D]]
    /// Identity of the route this was built from, so a stale cache is never reused.
    private let legIDs: [RouteLeg.ID]

    let minLat: CLLocationDegrees
    let maxLat: CLLocationDegrees
    let minLng: CLLocationDegrees
    let maxLng: CLLocationDegrees

    /// `nil` for a route with no legs — nothing to draw and nothing to frame.
    init?(_ result: RouteResult) {
        guard !result.legs.isEmpty else { return nil }

        var polylines: [RouteLeg.ID: [CLLocationCoordinate2D]] = [:]
        polylines.reserveCapacity(result.legs.count)

        var minLat = CLLocationDegrees.greatestFiniteMagnitude
        var maxLat = -CLLocationDegrees.greatestFiniteMagnitude
        var minLng = CLLocationDegrees.greatestFiniteMagnitude
        var maxLng = -CLLocationDegrees.greatestFiniteMagnitude

        func extend(lat: CLLocationDegrees, lng: CLLocationDegrees) {
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLng = min(minLng, lng); maxLng = max(maxLng, lng)
        }

        for leg in result.legs {
            let coords = leg.polylineCoordinates.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
            }
            polylines[leg.id] = coords
            for coord in coords { extend(lat: coord.latitude, lng: coord.longitude) }
            // Endpoints go into the box but never into the drawn line: a walk leg
            // MKDirections couldn't route has no geometry at all, and framing on polylines
            // alone would push the origin (or destination) pin off screen.
            extend(lat: leg.fromStation.coordinates.lat, lng: leg.fromStation.coordinates.lng)
            extend(lat: leg.toStation.coordinates.lat,   lng: leg.toStation.coordinates.lng)
        }

        self.polylines = polylines
        self.legIDs = result.legs.map(\.id)
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
    }

    func matches(_ result: RouteResult) -> Bool {
        legIDs.elementsEqual(result.legs.lazy.map(\.id))
    }
}
