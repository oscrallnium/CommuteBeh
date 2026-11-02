//
//  ContentView+Lifecycle.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI
import MapKit

// MARK: - Observers and tasks
// `observed(_:)` is internal because `ContentView.body` calls it. The rest stay private to
// this file.

extension ContentView {

    /// Attaches every `onChange`, `onAppear`, `onDisappear`, and `task` modifier the screen needs.
    func observed(_ content: some View) -> some View {
        let located = locationObservers(content)
        let looping = commuteLoops(located)
        let camera = cameraObservers(looping)
        let routed = routeObservers(camera)
        return screenLifecycle(routed)
    }

    // MARK: Location

    private func locationObservers(_ content: some View) -> some View {
        content
            // Auto-set origin: fills the empty origin field on the first GPS fix. See
            // `Commute.md`.
            .onChange(of: routeStore.userLocation, initial: true) { _, newValue in
                autoSetOrigin(from: newValue)
            }
            // The one seam that notices the app came back from the background at all —
            // see `autoSetOriginText`'s and `wasBackgrounded`'s doc comments.
            .onChange(of: scenePhase) { _, new in
                updateVisualLoops(for: new)
                if new == .background {
                    wasBackgrounded = true
                    saveCommute()
                    return
                }
                guard new == .active, wasBackgrounded, !isCommuting else { return }
                wasBackgrounded = false
                refreshAutoSetOrigin()
                if hasAutoSetOrigin, originText == autoSetOriginText {
                    hasAutoSetOrigin = false
                }
            }
            // Accuracy circle — only shown when the fix is notably imprecise. Below the
            // threshold the circle is smaller than the puck and adds no information, which
            // matches Maps' own behaviour (circle absent with a good outdoor fix).
            .onChange(of: routeStore.userHorizontalAccuracy) { _, newValue in
                let visible = (newValue ?? 0) > Self.accuracyCircleThresholdMeters ? newValue : nil
                withAnimation(DesignTokens.Motion.accuracyChange) {
                    displayedAccuracyRadius = visible
                }
            }
            // Live leg progress, active only during Commute Mode. See `Commute.md`.
            .onChange(of: routeStore.userLocation) { _, newValue in
                guard isCommuting, let newValue else { return }
                let now = Date()
                positionResolver.recordFix(newValue, speed: routeStore.userSpeed, at: now)
                noteLiveActivityFix(at: now)
                commuteEngine?.update(location: newValue, now: now)
                #if DEBUG
                print("[CameraDebug] userLocation fix following=\(isFollowingPassenger) transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                evaluateReroute(at: newValue, now: now)
            }
            // Every new snap target starts the puck's own glide toward it. See `Commute.md`.
            .onChange(of: commuteEngine?.snappedLocation) { _, newValue in
                #if DEBUG
                print("[CameraDebug] snappedLocation changed transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                guard isCommuting, let newValue else { return }
                puckInterpolator.move(to: newValue)
            }
    }

    private func autoSetOrigin(from newValue: Coordinates?) {
        guard !hasAutoSetOrigin,
              let newValue,
              routeStore.originID.isEmpty,
              !isCommuting else { return }
        hasAutoSetOrigin = true
        routeStore.setOriginCoordinate(newValue)
        routeStore.confirmedOriginLabel = "My Location"
        originText = "My Location"
        autoSetOriginText = "My Location"
        // Recentres on this fix — see `Commute.md` for when this actually matters.
        recenterHome()
        Task {
            let loc = CLLocation(latitude: newValue.lat, longitude: newValue.lng)
            guard let request = MKReverseGeocodingRequest(location: loc) else { return }
            let items = await withCheckedContinuation { (cont: CheckedContinuation<[MKMapItem], Never>) in
                request.getMapItems { items, _ in cont.resume(returning: items ?? []) }
            }
            guard let item = items.first,
                  routeStore.originID == RouteRequest.virtualOriginID else { return }
            let address = item.address?.shortAddress ?? item.address?.fullAddress
            guard let address else { return }
            routeStore.confirmedOriginLabel = address
            originText = address
            autoSetOriginText = address
        }
    }

    /// Moves the auto-filled origin to the live fix. Leaves an origin the passenger chose alone.
    func refreshAutoSetOrigin() {
        guard autoSetOriginText != nil,
              originText == autoSetOriginText,
              routeStore.originID == RouteRequest.virtualOriginID,
              let location = routeStore.userLocation else { return }
        routeStore.originCoordinate = location
    }

    // MARK: Commute loops

    private func commuteLoops(_ content: some View) -> some View {
        content
            // Elapsed time keeps moving even between sparse GPS fixes — standing on a
            // platform shouldn't freeze "how late am I" until the next one arrives.
            .task(id: isCommuting) { await runOnTimeStatusLoop() }
            // Dead-reckoning tick: runs at 1 Hz while commuting. See `Commute.md`.
            .task(id: isCommuting) { await runDeadReckoningLoop() }
            // Continuous camera follow, ticking at the puck's own 30 Hz cadence instead
            // of writing a new camera position once per GPS fix. See `Commute.md`.
            .task(id: isCommuting) { await runCameraFollowLoop() }
            // Road-leg times follow live traffic: first pass after 30 s, then every 5 minutes.
            .task(id: isCommuting) { await runTrafficRefreshLoop() }
    }

    private func runOnTimeStatusLoop() async {
        guard isCommuting else { return }
        while !Task.isCancelled {
            commuteEngine?.recomputeOnTimeStatus(now: .now)
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func runDeadReckoningLoop() async {
        guard isCommuting else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isCommuting else { return }
            let now = Date.now
            tickLiveActivity(now: now)
            guard isCommuting else { return }
            positionResolver.tick(context: commuteEngine?.currentLegProjectionContext, now: now)
            guard positionResolver.isDeadReckoned,
                  let projected = positionResolver.resolvedCoordinate else { continue }
            let isTrainLeg = commuteEngine.flatMap { currentCommuteLeg(for: $0) }?.mode == .train
            if isTrainLeg {
                // Only advance the track-snapped dot when the passenger was moving
                // before signal loss — a stationary passenger's last confirmed
                // position must hold, not creep forward at the line's schedule speed.
                guard positionResolver.isProjectingForward else { continue }
                commuteEngine?.deadReckonTrainLeg(now: now)
            } else {
                commuteEngine?.update(location: projected, now: now)
            }
        }
    }

    private func runCameraFollowLoop() async {
        guard isCommuting else { return }
        while !Task.isCancelled {
            let isSuspended = puckInterpolator.isSuspended
            try? await Task.sleep(for: .seconds(isSuspended ? 1 : DesignTokens.Motion.headingTickInterval))
            guard !Task.isCancelled, isCommuting else { return }
            guard !puckInterpolator.isSuspended else { continue }
            advanceSmoothedRouteHeading()
            guard isFollowingPassenger, !isCameraTransitioning, !isEnteringCommute else { continue }
            updateCommuteCamera(.followTick)
        }
    }

    /// Pauses the 30 Hz visual loops in the background. On return to active, the puck, heading,
    /// and follow camera jump to the current position at once. `.inactive` changes nothing.
    private func updateVisualLoops(for phase: ScenePhase) {
        if phase == .background { puckInterpolator.suspend() }
        guard phase == .active, puckInterpolator.isSuspended else { return }
        puckInterpolator.resume()
        guard isCommuting else { return }
        smoothedRouteHeading = nil
        lastHeadingSample = nil
        advanceSmoothedRouteHeading()
        guard isFollowingPassenger, !isCameraTransitioning, !isEnteringCommute else { return }
        updateCommuteCamera(.followTick)
    }

    private func runTrafficRefreshLoop() async {
        guard isCommuting else { return }
        try? await Task.sleep(for: .seconds(30))
        while !Task.isCancelled, isCommuting {
            await refreshRoadTraffic()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Drops the result when a reroute changed the leg minutes during the request.
    private func refreshRoadTraffic() async {
        guard let engine = commuteEngine else { return }
        let before = engine.result
        let index = engine.currentLegIndex
        guard before.legs.indices.contains(index),
              before.legs[index...].contains(where: RoadTraffic.isRoadLeg) else { return }

        guard let retimed = await RoadTraffic.retimed(
            before,
            legIndex: index,
            live: routeStore.userLocation,
            metersInto: engine.metersIntoCurrentLeg,
            metersRemaining: engine.metersRemainingOnCurrentLeg
        ), isCommuting,
           engine.result.legs.map(\.effectiveTravelMinutes) == before.legs.map(\.effectiveTravelMinutes)
        else { return }
        routeStore.routeResult = retimed
        engine.applyRetiming(retimed)
    }

    // MARK: Camera

    private func cameraObservers(_ content: some View) -> some View {
        content
            // While free-panning the switch changes the camera in place and keeps its centre.
            .onChange(of: commuteCameraMode) { oldValue, newValue in
                #if DEBUG
                print("[CameraDebug] commuteCameraMode \(oldValue) -> \(newValue) following=\(isFollowingPassenger) t=\(Date().timeIntervalSince1970)")
                #endif
                beginCameraTransition(isFollowingPassenger ? .followPassenger : .keepCenter)
            }
            .onChange(of: commuteEngine?.currentLegIndex) { _, _ in
                saveCommute()
                #if DEBUG
                print("[CameraDebug] currentLegIndex changed transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                guard isFollowingPassenger, !isCameraTransitioning else { return }
                updateCommuteCamera(.fit)
            }
            // Re-attaching glides back to the passenger and holds the follow loop off until the
            // glide lands. Detaching writes nothing and stops any running transition.
            .onChange(of: isFollowingPassenger) { _, following in
                #if DEBUG
                print("[CameraDebug] isFollowingPassenger -> \(following) t=\(Date().timeIntervalSince1970)")
                #endif
                guard following else {
                    cancelCameraTransition()
                    return
                }
                beginCameraTransition(.followPassenger)
            }
    }

    // MARK: Route

    private func routeObservers(_ content: some View) -> some View {
        content
            // Rebuild the cached geometry whenever the route itself changes — identity is
            // the leg list, since RouteLeg.id is a fresh UUID per computed route.
            .onChange(of: routeStore.routeResult?.legs.map(\.id), initial: true) { _, _ in
                routeGeometry = routeStore.routeResult.flatMap(RouteGeometry.init)
            }
            // Route choice: per-option map data, the active route, and the camera refit
            // after the sheet changes height. See `ContentView+RouteChoice.swift`.
            .onChange(of: routeChoiceKey, initial: true) { _, _ in syncRouteChoice() }
            .onChange(of: routeChoice.selectedID) { old, new in
                redrawSelectedRoute(from: old, to: new)
                previewSelectedRoute()
                placeRouteBubble()
            }
            .onChange(of: routeChoice.isDetailExpanded) { _, _ in
                Task { await refitForDetailToggle() }
            }
    }

    // MARK: Screen

    private func screenLifecycle(_ content: some View) -> some View {
        content
            // Live position for as long as the map is on screen — for the resting camera
            // and the search fields. The dot is MapKit's own (see `passengerContent`)
            // and does not come from here.
            .onAppear {
                routeStore.startTrackingUserLocation()
                isOnScreen = true
            }
            // The tab bar makes this fire on every tab switch, which is exactly when both
            // location feeds should stop.
            .onDisappear {
                if !isCommuting { routeStore.stopTrackingUserLocation() }
                isOnScreen = false
            }
            // Rests the camera on the passenger whenever no route is on screen. Keyed on the
            // strip as well as the fix, so the first centring waits for the panels to be measured.
            .task(id: HomeTrigger(hasUserLocation: routeStore.userLocation != nil,
                                  visibleTop: visibleTop,
                                  visibleBottom: visibleBottom,
                                  hasRoute: routeStore.routeResult != nil)) {
                // The `isLoading` guard is required: `calculateRoute()` clears `routeResult`
                // when a search starts, which makes this task eligible mid-search. Without it,
                // this races `fitToRouteIfSuccessful` and MapKit drops one camera animation.
                guard routeStore.routeResult == nil, !routeStore.isLoading else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                recenterHome()
            }
            .task { await restoreCommuteIfNeeded() }
            .task(id: routeStore.isLoading) {
                if routeStore.isLoading {
                    try? await Task.sleep(for: DesignTokens.Motion.progressGraceDelay)
                    if routeStore.isLoading { showSearchProgress = true }
                } else if showSearchProgress {
                    try? await Task.sleep(for: DesignTokens.Motion.progressMinVisible)
                    showSearchProgress = false
                }
            }
            #if DEBUG
            // Launch-argument-gated; see DebugRouteSeed. No-op without `-seedRoute`.
            .task {
                guard DebugRouteSeed.isEnabled else { return }
                let seeded = await DebugRouteSeed.apply(to: routeStore)
                // Assigned after confirming on the view model, so the fields' onChange
                // reads these as a programmatic echo rather than a user edit.
                if let origin = seeded.origin { originText = origin }
                if let destination = seeded.destination { destinationText = destination }
                routeDrawAnimator.prepareForNewRoute()
                await DebugRouteSeed.searchIfRequested(on: routeStore)
                await fitToRouteIfSuccessful()
            }
            #endif
    }
}
