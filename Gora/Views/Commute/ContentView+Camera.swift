//
//  ContentView+Camera.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Camera and route framing
// Three things move the map camera: a new route, a location fix, and Commute Mode.
// These members are internal rather than private only because they sit in a different file
// from the stored properties they read. Nothing outside `ContentView` calls them.

extension ContentView {

    /// Animates the camera to the route a search produced, and does nothing when the search
    /// failed. Waits for `visibleTop` and `visibleBottom` to settle first, because both
    /// panels animate their height and an intermediate strip frames the route wrongly.
    func fitToRouteIfSuccessful() async {
        guard let result = routeStore.routeResult else { return }
        var lastTop = visibleTop
        var lastBottom = visibleBottom
        while true {
            try? await Task.sleep(for: .milliseconds(80))
            if visibleTop == lastTop, visibleBottom == lastBottom { break }
            lastTop = visibleTop
            lastBottom = visibleBottom
        }
        fitMap(to: result)
    }

    // Fits the camera to the bounding box of all leg polylines, shifted northward
    // so the route is fully visible in the map area above the results panel.
    func fitMap(to result: RouteResult) {
        // The bounding box is precomputed per route — see RouteGeometry, which also
        // explains why leg endpoints are folded into it and not just the drawn polylines.
        guard let geo = geometry(for: result) else { return }
        var center = CLLocationCoordinate2D(
            latitude:  (geo.minLat + geo.maxLat) / 2,
            longitude: (geo.minLng + geo.maxLng) / 2
        )
        // 1.2x padding puts the route at about 88% of the strip's width, leaving an 8% margin
        // on every side.
        var latDelta = max((geo.maxLat - geo.minLat) * 1.2, 0.01)
        let lngDelta = max((geo.maxLng - geo.minLng) * 1.2, 0.01)

        // Shifts the centre and expands the span so the route sits between the search pill and
        // the results panel. The map renders edge to edge, so both panels cover it rather than
        // reserving space, and the strip between them is measured.
        if let strip = visibleStrip {
            // Inflate so the *box* fits the strip rather than the screen. A point target
            // (see `recenterHome`) has no extent and skips this.
            latDelta = latDelta / strip.visible
            center.latitude = shiftedIntoStrip(center.latitude, latDelta: latDelta,
                                               lngDelta: lngDelta, strip: strip)
        }

        moveCamera(to: MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
        ))
    }

    /// Fractions of the screen hidden above and below the map strip the passenger can
    /// see, and what is left between them. `nil` before the panels have been measured.
    var visibleStrip: (top: CGFloat, bottom: CGFloat, visible: CGFloat)? {
        let screenH = UIScreen.main.bounds.height
        let stripBottom = visibleBottom > 0 ? visibleBottom : screenH
        guard screenH > 0, stripBottom > visibleTop else { return nil }
        let top    = visibleTop / screenH
        let bottom = (screenH - stripBottom) / screenH
        return (top, bottom, max(1.0 - top - bottom, 0.05))
    }

    /// Moves a camera latitude so its subject lands at the middle of the visible strip
    /// rather than the middle of the screen. Measures the shift against the span MapKit
    /// renders, which is the larger of the two deltas, not the span it was handed.
    func shiftedIntoStrip(_ latitude: CLLocationDegrees,
                                  latDelta: CLLocationDegrees,
                                  lngDelta: CLLocationDegrees,
                                  strip: (top: CGFloat, bottom: CGFloat, visible: CGFloat))
    -> CLLocationDegrees {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0 else { return latitude }
        let metresPerLatDegree = 110_574.0
        let metresPerLngDegree = 111_320.0 * cos(latitude * .pi / 180)
        let metresPerPoint = max(lngDelta * metresPerLngDegree / screen.width,
                                 latDelta * metresPerLatDegree / screen.height)
        let renderedLatDelta = metresPerPoint * screen.height / metresPerLatDegree
        return latitude - renderedLatDelta * (strip.bottom - strip.top) / 2
    }

    /// The camera for the no-route state: the passenger's own position when there is a
    /// fix, the Manila default when there is not — either way sitting at the middle of
    /// the visible strip rather than the middle of the screen.
    func recenterHome() {
        let target = routeStore.userLocation.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        } ?? Self.manilaRegion.center
        let span = Self.manilaRegion.span

        var center = target
        if let strip = visibleStrip {
            center.latitude = shiftedIntoStrip(target.latitude,
                                               latDelta: span.latitudeDelta,
                                               lngDelta: span.longitudeDelta,
                                               strip: strip)
        }
        moveCamera(to: MKCoordinateRegion(center: center, span: span))
    }

    /// Animates the camera to `region`, writing back the same `MapCameraPosition` case that
    /// `mapPosition` currently holds. `withAnimation` only glides within one case, and a
    /// mismatched case drops the animation and snaps.
    func moveCamera(to region: MKCoordinateRegion) {
        let target: MapCameraPosition
        if let proxy = mapProxy, mapPosition.region == nil {
            target = .camera(proxy.camera(framing: region))
        } else {
            target = .region(region)
        }
        withAnimation(DesignTokens.Motion.cameraFit) {
            mapPosition = target
        }
    }

    /// What triggered a `updateCommuteCamera` call — each source paces its glide
    /// differently, so the animation is picked here rather than left to a bool flag.
    enum CameraFollowTrigger {
        /// A route fit, a leg switch, or a camera-mode change — infrequent, deliberate
        /// jumps that read better eased with `cameraFit`.
        case fit
        /// One GPS fix. Paced to the time since the previous fix, so consecutive glides
        /// hand off the way heading ticks do instead of decelerating to a stop between
        /// fixes.
        case location(elapsedSinceLastFix: TimeInterval)
        /// A train leg's track-snap landing after `TrackSnapper`'s actor call resolves,
        /// later than the fix that triggered it. Short and linear: this corrects that
        /// fix's glide, it is not a new one.
        case locationCorrection
        /// One tick of a 2D/3D pose transition's own interpolation loop (see
        /// `beginCameraTransition()`). Duration-matched to that loop's tick cadence.
        case poseTransition
    }

    /// The passenger's best live position: the engine's snapped point when one is
    /// available, the raw GPS fix otherwise. `nil` before either has ever reported
    /// one. Also what the live route polyline trims against — see `ContentView.body`.
    var livePassengerCoordinate: CLLocationCoordinate2D? {
        if let snapped = commuteEngine?.snappedLocation {
            return CLLocationCoordinate2D(latitude: snapped.lat, longitude: snapped.lng)
        }
        if let userLocation = routeStore.userLocation {
            return CLLocationCoordinate2D(latitude: userLocation.lat, longitude: userLocation.lng)
        }
        return nil
    }

    /// What the live route polyline actually trims against — `livePassengerCoordinate`,
    /// except during a camera transition, when it holds still at `frozenTrimCoordinate`
    /// instead. A fix landing mid-glide still reaches `commuteEngine` (progress tracking
    /// stays live either way), but reading the live coordinate here too would rebuild the
    /// Map's polyline content on every fix, fighting the glide for the same render pass.
    var polylineTrimCoordinate: CLLocationCoordinate2D? {
        isCameraTransitioning ? frozenTrimCoordinate : livePassengerCoordinate
    }

    /// Commute Mode's camera write, called on every fix so the view keeps following.
    /// Writes `.camera(...)` directly, because pitch and heading have no `.region` form.
    /// Centres on the passenger's live position, falling back to the leg's start.
    ///
    /// `distanceOverride`/`pitchOverride` let `beginCameraTransition()` write an
    /// already-interpolated pose for one tick of its own transition loop, rather than
    /// jumping straight to `commuteCameraMode`'s target values.
    func updateCommuteCamera(
        _ trigger: CameraFollowTrigger = .fit,
        distanceOverride: CLLocationDistance? = nil,
        pitchOverride: Double? = nil
    ) {
        guard isCommuting else { return }
        let center: CLLocationCoordinate2D
        if let livePassengerCoordinate {
            center = livePassengerCoordinate
        } else if let engine = commuteEngine, let leg = currentCommuteLeg(for: engine) {
            center = CLLocationCoordinate2D(latitude: leg.fromStation.coordinates.lat,
                                            longitude: leg.fromStation.coordinates.lng)
        } else {
            return
        }
        let heading = 0.0
        let animation: Animation
        switch trigger {
        case .fit: animation = DesignTokens.Motion.cameraFit
        case .location(let elapsed): animation = DesignTokens.Motion.locationFollow(elapsedSinceLastFix: elapsed)
        case .locationCorrection: animation = DesignTokens.Motion.locationCorrection
        case .poseTransition: animation = DesignTokens.Motion.headingFollow
        }
        let camera = MapCamera(
            centerCoordinate: center,
            distance: distanceOverride ?? commuteCameraMode.distance,
            heading: heading,
            pitch: pitchOverride ?? commuteCameraMode.pitch
        )
        #if DEBUG
        print("[CameraDebug] write trigger=\(trigger) heading=\(heading.rounded()) pitch=\(camera.pitch) distance=\(camera.distance) transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
        #endif
        withAnimation(animation) {
            mapPosition = .camera(camera)
        }
    }

    /// The cached geometry when it belongs to `result`, otherwise a freshly built one.
    /// The fallback covers the one frame where `body` runs before the `.onChange` that
    /// refills the cache. Steady state is a dictionary lookup.
    func geometry(for result: RouteResult) -> RouteGeometry? {
        if let routeGeometry, routeGeometry.matches(result) { return routeGeometry }
        return RouteGeometry(result)
    }
}
