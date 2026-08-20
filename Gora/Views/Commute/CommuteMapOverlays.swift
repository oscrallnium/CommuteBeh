//
//  CommuteMapOverlays.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import MapKit
import CoreLocation

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

// MARK: - Map Controls

/// 2D/3D and follow controls, floated on the map itself above the bottom card —
/// so they stay in the same spot whether the card is compact or expanded.
struct CommuteMapControls: View {
    @Binding var cameraMode: CommuteCameraMode
    /// Whether the camera stays locked to the passenger. While true the follow loop rewrites the
    /// camera and the map cannot be panned, so this is what a passenger turns off to look ahead.
    @Binding var isFollowing: Bool

    var body: some View {
        VStack(spacing: 10) {
            cameraToggleButton
            followToggleButton
        }
    }

    /// Follow and recentre in one control: turning follow back on glides the camera to the
    /// passenger, so there is nothing left for a separate recentre button to do.
    private var followToggleButton: some View {
        Button {
            isFollowing.toggle()
        } label: {
            Image(systemName: isFollowing ? "location.fill.viewfinder" : "location.slash")
                .font(.caption.weight(.heavy))
                .foregroundStyle(isFollowing ? DesignTokens.Colors.action : Color.charcoal)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignTokens.Colors.paper))
                .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 1))
                .cardShadow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFollowing ? "Stop following your location" : "Follow your location")
    }

    /// Shows the mode tapping switches *to* — Apple Maps' own convention for this
    /// control, and why it reads "3D" while the map is actually in 2D.
    private var cameraToggleButton: some View {
        Button {
            cameraMode = cameraMode == .twoD ? .threeD : .twoD
        } label: {
            Text(cameraMode == .twoD ? "3D" : "2D")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.charcoal)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignTokens.Colors.paper))
                .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 1))
                .cardShadow()
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Speed & Distance Readout

/// Live speed and distance-to-next-stop, floated over the map above the bottom card.
/// White-on-map like Apple/Google Maps' own turn-by-turn readouts, since it sits over
/// map tiles rather than app chrome and needs to read in both light and dark map styles.
struct CommuteSpeedReadout: View {
    let speedMetersPerSecond: CLLocationSpeed?
    let metersRemaining: CLLocationDistance
    let nextStopName: String

    private var speedKmh: Int? {
        guard let speedMetersPerSecond, speedMetersPerSecond >= 0 else { return nil }
        return Int((speedMetersPerSecond * 3.6).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speedKmh {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(speedKmh)")
                        .font(.system(size: 32, weight: .bold))
                    Text("km/h")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(RouteCardSummary.distanceLabel(metersRemaining / 1000))
                    .font(.title3.weight(.bold))
                if !nextStopName.isEmpty {
                    Text("to \(nextStopName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
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

// MARK: - Live Route Polyline (Commute Mode)

/// `coords` trimmed to the portion still ahead of `passenger` — the travelled part
/// behind is dropped, matching standard turn-by-turn convention where the line shows
/// only what's left. Projects onto the nearest segment rather than the nearest vertex,
/// so the trim point slides smoothly along a sparse polyline instead of jumping
/// vertex to vertex. Returns `coords` unchanged when `passenger` is `nil` or there
/// are fewer than two points to project onto.
func aheadPolyline(_ coords: [CLLocationCoordinate2D], from passenger: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D] {
    guard let passenger, coords.count >= 2 else { return coords }
    let passengerLocation = CLLocation(latitude: passenger.latitude, longitude: passenger.longitude)

    var bestIndex = 0
    var bestDistance = CLLocationDistance.greatestFiniteMagnitude
    var bestPoint = coords[0]

    for i in 0..<(coords.count - 1) {
        let a = coords[i], b = coords[i + 1]
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lengthSquared = dx * dx + dy * dy
        let t: Double = lengthSquared > 0
            ? max(0, min(1, ((passenger.longitude - a.longitude) * dx + (passenger.latitude - a.latitude) * dy) / lengthSquared))
            : 0
        let projected = CLLocationCoordinate2D(latitude: a.latitude + t * dy, longitude: a.longitude + t * dx)
        let distance = passengerLocation.distance(from: CLLocation(latitude: projected.latitude, longitude: projected.longitude))
        if distance < bestDistance {
            bestDistance = distance
            bestIndex = i
            bestPoint = projected
        }
    }
    return [bestPoint] + coords[(bestIndex + 1)...]
}

/// One leg's polyline exactly as `RouteGeometry` computed it — the non-commuting route
/// preview, and every leg still ahead of the passenger in Commute Mode. A leg
/// MKDirections couldn't route has no geometry and draws nothing on purpose; never
/// fall back to connecting its endpoints here (`currentLegPolylineContent` below is
/// where that rule is different, and why).
@MapContentBuilder
func routePolylineContent(leg: RouteLeg, coords: [CLLocationCoordinate2D]) -> some MapContent {
    if coords.count < 2 {
        EmptyMapContent()
    } else if leg.line == "ACCESS_WALK" {
        MapPolyline(coordinates: coords)
            .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
    } else {
        MapPolyline(coordinates: coords)
            .stroke(leg.mode.color, lineWidth: leg.mode.lineWidth)
    }
}

/// The leg the passenger is currently on: drawn from their live position onward, never
/// from the leg's own start, so the line only ever shows what's left to travel.
///
/// When the leg has no real geometry (an access walk MKDirections couldn't route),
/// falls back to a straight guide line to the leg's own destination station, trimmed
/// the same way. That fallback is deliberately different from `routePolylineContent`'s
/// "never connect the endpoints" rule: that rule protects the route *preview* from
/// implying a path that was never confirmed, but once the passenger is actively
/// walking it, a straight guide is more useful than a blank map — and because it's
/// trimmed like any other leg, it shrinks to nothing and disappears once they reach
/// the leg's own station, the same moment `CommuteProgressEngine` moves them onto the
/// next leg.
@MapContentBuilder
func currentLegPolylineContent(
    leg: RouteLeg, coords: [CLLocationCoordinate2D], passenger: CLLocationCoordinate2D?
) -> some MapContent {
    let hasRealGeometry = coords.count >= 2
    let baseCoords: [CLLocationCoordinate2D] = hasRealGeometry ? coords : [
        CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat, longitude: leg.fromStation.coordinates.lng),
        CLLocationCoordinate2D(latitude: leg.toStation.coordinates.lat, longitude: leg.toStation.coordinates.lng)
    ]
    let ahead = aheadPolyline(baseCoords, from: passenger)

    if ahead.count < 2 {
        EmptyMapContent()
    } else if !hasRealGeometry || leg.line == "ACCESS_WALK" {
        MapPolyline(coordinates: ahead)
            .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
    } else {
        MapPolyline(coordinates: ahead)
            .stroke(leg.mode.color, lineWidth: leg.mode.lineWidth)
    }
}
