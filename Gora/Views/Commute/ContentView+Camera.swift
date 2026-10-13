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
    /// Starts the polyline draw-on only once that camera glide has landed — the same order
    /// Maps apps use: settle the frame first, then draw the route inside it.
    func fitToRouteIfSuccessful() async {
        guard let result = routeStore.routeResult else { return }
        await waitForPanelsToSettle()
        if let bounds = routeChoice.unionBounds {
            fitMap(bounds: bounds)
        } else {
            fitMap(to: result)
        }
        try? await Task.sleep(for: .seconds(DesignTokens.Motion.cameraFitDuration))
        guard routeStore.routeResult != nil else { return }
        routeDrawAnimator.start()
        routeChoice.revealBubbles()
    }

    /// Returns once `visibleTop` and `visibleBottom` stop changing between two polls.
    func waitForPanelsToSettle() async {
        var lastTop = visibleTop
        var lastBottom = visibleBottom
        while true {
            try? await Task.sleep(for: .milliseconds(80))
            if visibleTop == lastTop, visibleBottom == lastBottom { return }
            lastTop = visibleTop
            lastBottom = visibleBottom
        }
    }

    // Fits the camera to the bounding box of all leg polylines, shifted northward
    // so the route is fully visible in the map area above the results panel.
    func fitMap(to result: RouteResult) {
        // The bounding box is precomputed per route — see RouteGeometry, which also
        // explains why leg endpoints are folded into it and not just the drawn polylines.
        guard let geo = geometry(for: result) else { return }
        fitMap(bounds: RouteBounds(geo))
    }

    /// Fits the camera to `geo`, which may span several routes.
    func fitMap(bounds geo: RouteBounds, animation: Animation = DesignTokens.Motion.cameraFit) {
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
        ), animation: animation)
    }

    /// Size of the screen that shows the app's window scene. Zero before a scene connects.
    var screenSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first ?? .zero
    }

    /// Fractions of the screen hidden above and below the map strip the passenger can
    /// see, and what is left between them. `nil` before the panels have been measured.
    var visibleStrip: (top: CGFloat, bottom: CGFloat, visible: CGFloat)? {
        let screenH = screenSize.height
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
        let screen = screenSize
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
        #if DEBUG
        if debugSimHoldsCamera { return }
        #endif
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
    func moveCamera(to region: MKCoordinateRegion, animation: Animation = DesignTokens.Motion.cameraFit) {
        let target: MapCameraPosition
        if let proxy = mapProxy, mapPosition.region == nil {
            target = .camera(proxy.camera(framing: region))
        } else {
            target = .region(region)
        }
        withAnimation(animation) {
            mapPosition = target
        }
    }

    /// What triggered a `updateCommuteCamera` call — each source paces its glide
    /// differently, so the animation is picked here rather than left to a bool flag.
    enum CameraFollowTrigger {
        /// A route fit or a leg switch — infrequent, deliberate jumps that read
        /// better eased with `cameraFit`.
        case fit
        /// Entering Commute Mode for the first time this session — glides from wherever
        /// the camera already sat, eased like `.fit`. See `Commute.md`.
        case start
        /// One tick of the continuous follow loop (see the `isCommuting`-keyed `.task`
        /// in `ContentView.body`). Duration-matched to that loop's own cadence, so
        /// consecutive ticks hand off with no gap and no overlap.
        case followTick
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

    /// The puck's 30 Hz glide position, then the engine's snapped fix, then the raw GPS fix.
    /// The puck annotation, the live polyline trim point, and the camera centre all read it, so
    /// the line never shows a segment behind the puck. See `Commute.md`.
    var displayedPuckCoordinate: CLLocationCoordinate2D? {
        if let displayed = puckInterpolator.displayedCoordinate {
            return CLLocationCoordinate2D(latitude: displayed.lat, longitude: displayed.lng)
        }
        return livePassengerCoordinate
    }

    /// Commute Mode's camera write for the current mode's pose. Writes `.camera(...)`
    /// directly, because pitch and heading have no `.region` form. See `Commute.md`.
    func updateCommuteCamera(_ trigger: CameraFollowTrigger = .fit) {
        guard isCommuting else {
            #if DEBUG
            print("[CameraDebug] updateCommuteCamera SKIPPED not-commuting trigger=\(trigger) t=\(Date().timeIntervalSince1970)")
            #endif
            return
        }
        guard let pose = targetPose(commuteCameraMode) else {
            #if DEBUG
            print("[CameraDebug] updateCommuteCamera SKIPPED no-center trigger=\(trigger) t=\(Date().timeIntervalSince1970)")
            #endif
            return
        }
        let animation: Animation?
        switch trigger {
        case .fit, .start: animation = DesignTokens.Motion.cameraFit
        case .followTick: animation = nil
        }
        // A follow tick otherwise keeps writing the same target every tick while the
        // passenger stands still. Restarting the animation each time never lets it
        // settle, so skip once a tick lands within noise of the last one.
        if case .followTick = trigger, hasArrived(at: pose) {
            #if DEBUG
            print("[CameraDebug] updateCommuteCamera SKIPPED already-there trigger=\(trigger) t=\(Date().timeIntervalSince1970)")
            #endif
            return
        }
        // `withAnimation` only glides within one `MapCameraPosition` case, and entering
        // Commute Mode starts from whatever the search screen left behind — usually a
        // `.region` fit to the route. Re-express it as the equivalent `.camera` first, with
        // no animation, so the write below glides from that position rather than a mismatched
        // case dropping the animation and cutting straight to the destination.
        if case .start = trigger, let region = mapPosition.region, let proxy = mapProxy {
            mapPosition = .camera(proxy.camera(framing: region))
        }
        #if DEBUG
        print("[CameraDebug] write trigger=\(trigger) center=(\(pose.center.latitude),\(pose.center.longitude)) heading=\(pose.heading.rounded()) pitch=\(pose.pitch) distance=\(pose.distance) animation=\(animation == nil ? "none" : "\(animation!)") isFollowing=\(isFollowingPassenger) transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
        #endif
        writeCamera(pose, animation: animation)
    }

    /// Writes `pose` to the map and records it as the last camera this view wrote.
    func writeCamera(_ pose: CommuteCameraPose, animation: Animation?) {
        lastCommuteCameraCenter = pose.center
        lastCommuteCameraDistance = pose.distance
        lastCommuteCameraPitch = pose.pitch
        lastCommuteCameraHeading = pose.heading
        let camera = MapCamera(centerCoordinate: pose.center, distance: pose.distance,
                               heading: pose.heading, pitch: pose.pitch)
        withAnimation(animation) {
            mapPosition = .camera(camera)
        }
    }

    /// Shifts `coordinate` so the puck lands `fraction` of the way down the map strip between
    /// the status bar and the speed row, and at the horizontal middle of the screen. Measures
    /// the shift against the camera the map shows now. Returns `coordinate` unchanged until
    /// the proxy and the strip are available.
    func positionedInStrip(_ coordinate: CLLocationCoordinate2D, fraction: CGFloat) -> CLLocationCoordinate2D {
        let now = Date()
        guard commuteStripBottom > 0 else { return coordinate }
        if stripBottomEase == nil { stripBottomEase = StripBottomEase(commuteStripBottom, now: now) }
        stripBottomEase?.retarget(commuteStripBottom, now: now)
        guard let proxy = mapProxy,
              let bottom = stripBottomEase?.value(at: now) else { return coordinate }
        let screen = screenSize
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 0
        guard bottom > top else { return coordinate }
        let screenCentre = CGPoint(x: screen.width / 2, y: screen.height / 2)
        let stripPoint = CGPoint(x: screen.width / 2, y: top + (bottom - top) * fraction)
        guard let screenCoordinate = proxy.convert(screenCentre, from: .local),
              let stripCoordinate = proxy.convert(stripPoint, from: .local) else { return coordinate }
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + screenCoordinate.latitude - stripCoordinate.latitude,
            longitude: coordinate.longitude + screenCoordinate.longitude - stripCoordinate.longitude
        )
    }

    /// Degrees, metres, and degrees below which two follow-tick targets are the same
    /// passenger-visible camera position. Far under a real GPS fix's movement, so this
    /// only catches the sub-millimetre noise `updateCommuteCamera` produces at rest.
    private static let followArrivalDegrees: CLLocationDegrees = 0.0000001
    private static let followArrivalMetres: CLLocationDistance = 0.5
    private static let followArrivalPitchDegrees: Double = 0.5

    private static let followArrivalHeadingDegrees: Double = 0.5

    /// True when `pose` matches the last camera this view wrote, within `followArrival...`
    /// tolerance.
    func hasArrived(at pose: CommuteCameraPose) -> Bool {
        guard let lastCenter = lastCommuteCameraCenter,
              let lastDistance = lastCommuteCameraDistance,
              let lastPitch = lastCommuteCameraPitch,
              let lastHeading = lastCommuteCameraHeading else { return false }
        return abs(lastCenter.latitude - pose.center.latitude) < Self.followArrivalDegrees
            && abs(lastCenter.longitude - pose.center.longitude) < Self.followArrivalDegrees
            && abs(lastDistance - pose.distance) < Self.followArrivalMetres
            && abs(lastPitch - pose.pitch) < Self.followArrivalPitchDegrees
            && abs(Self.headingDifference(pose.heading, lastHeading)) < Self.followArrivalHeadingDegrees
    }

    /// The cached geometry when it belongs to `result`, otherwise a freshly built one.
    /// The fallback covers the one frame where `body` runs before the `.onChange` that
    /// refills the cache. Steady state is a dictionary lookup.
    func geometry(for result: RouteResult) -> RouteGeometry? {
        if let routeGeometry, routeGeometry.matches(result) { return routeGeometry }
        return RouteGeometry(result)
    }
}
