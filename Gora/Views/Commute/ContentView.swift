//
//  ContentView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 5/27/26.
//

import SwiftUI
import MapKit

// MARK: - ContentView

struct ContentView: View {
    @State var routeStore = RouteStore()
    @State var originText = ""
    @State var destinationText = ""
    @State var mapPosition: MapCameraPosition = .region(Self.manilaRegion)
    /// Captured once the map appears — see `moveCamera`.
    @State var mapProxy: MapProxy?
    @State private var showSearchProgress = false
    @FocusState private var focusedField: SearchField?
    @Namespace private var searchNS
    /// Edges of the map strip the passenger can see, in global window coordinates.
    /// Both come straight from the layout. Do not reconstruct them from panel heights and
    /// safe-area insets, which omit the tab bar this screen sits inside.
    @State var visibleTop: CGFloat = 0
    @State var visibleBottom: CGFloat = 0
    /// Top edge of the commute sheet while commuting. 0 when unmeasured.
    @State var commuteStripBottom: CGFloat = 0
    /// The strip bottom the follow camera uses. Eases toward `commuteStripBottom`.
    @State var stripBottomEase: StripBottomEase?
    /// Map-ready coordinates + bounding box for `vm.routeResult`. See `RouteGeometry`.
    @State var routeGeometry: RouteGeometry?
    /// Whether this tab is the one on screen. Gates the location dot — see `UserAnnotation`.
    @State private var isOnScreen = false
    /// Animated copy of `routeStore.userHorizontalAccuracy` — updated with easeInOut so
    /// the accuracy circle grows and shrinks smoothly rather than jumping between fixes.
    @State private var displayedAccuracyRadius: CLLocationAccuracy?
    /// True after the first GPS fix has been applied to the origin field automatically.
    /// Prevents subsequent fixes from overwriting an origin the user has since changed.
    @State private var hasAutoSetOrigin = false
    /// The exact text `hasAutoSetOrigin` last wrote — "My Location" or the reverse-geocoded
    /// address. Lets `scenePhase` tell "still what auto-fill wrote" apart from "the
    /// passenger has since edited or replaced it" before deciding to refresh it.
    @State private var autoSetOriginText: String?
    /// Watched so returning from the background can re-open two seams a stale position
    /// otherwise gets stuck behind. See `Commute.md`.
    @Environment(\.scenePhase) private var scenePhase
    /// The commute sheet stays down while the login cover is up.
    @Environment(UserSession.self) var session
    /// Set on `.background`, cleared on the next real `.active`. See `Commute.md`.
    @State private var wasBackgrounded = false
    /// Resolves the best available passenger position: real GPS when fresh, polyline-projected
    /// when fixes stop (tunnel, signal loss). See `CommutePositionResolver`.
    @State private var positionResolver = CommutePositionResolver()
    /// Glides the passenger dot between snapped positions at 30 Hz, because `Annotation`
    /// re-places its coordinate instantly rather than animating it. See `PuckGlideInterpolator`.
    @State var puckInterpolator = PuckGlideInterpolator()
    /// Draws a freshly computed route on progressively from origin to destination.
    /// Started by `fitToRouteIfSuccessful` in `ContentView+Camera.swift`, hence internal
    /// rather than private. See `RouteDrawAnimator`.
    @State var routeDrawAnimator = RouteDrawAnimator()
    /// Selection, sheet detail state, and per-option map data for the route-choice phase.
    /// See `RouteChoiceState`.
    @State var routeChoice = RouteChoiceState()
    /// Decides when the passenger has genuinely left the current walk leg. See `Commute.md`.
    @State private var rerouteMonitor = CommuteRerouteMonitor()

    // MARK: Commute Mode
    //
    // `commuteEngine` is non-nil exactly when `isCommuting` is true.
    @State var isCommuting = false
    @State var commuteEngine: CommuteProgressEngine?
    @State var commuteStartedAt: Date?
    /// Set when the passenger reaches the destination. The commute card shows "Arrived" until Done.
    @State var arrivedAt: Date?
    @State var commuteCameraMode: CommuteCameraMode = .twoD
    /// True while a 2D/3D camera transition loop is in flight.
    @State var isCameraTransitioning = false
    /// True from the start of `startCommute` until its `.fit` correction should have
    /// landed, so the follow loop's first ticks don't restart that glide underneath it.
    @State private var isEnteringCommute = false
    /// Identifies the entry window `startCommute` most recently opened, so a stale clear
    /// from an earlier call can't end a newer one early.
    @State private var commuteEntryToken = 0
    /// The camera values last written for commuting, so `.followTick` can tell it already
    /// reached this target and skip restarting an animation toward it. See `Commute.md`.
    @State var lastCommuteCameraCenter: CLLocationCoordinate2D?
    @State var lastCommuteCameraDistance: CLLocationDistance?
    @State var lastCommuteCameraPitch: Double?
    @State var lastCommuteCameraHeading: Double?
    /// The route heading the 3D camera faces, low-passed once per follow tick. See `Commute.md`.
    @State var smoothedRouteHeading: Double?
    /// Ground metres that `RouteLine.walkPitch` points span at the puck. See `ContentView+WalkGrid.swift`.
    @State var walkGridStep: CLLocationDistance?
    @State var walkGridStepUpdatedAt: Date?
    /// The puck position at the last heading tick. The heading holds while the puck stands still.
    @State var lastHeadingSample: CLLocationCoordinate2D?
    /// Whether the camera stays locked to the passenger. While true the follow loop rewrites the
    /// camera every tick, which discards any pan, so a passenger turns this off to move the map.
    @State var isFollowingPassenger = true
    #if DEBUG
    /// Drives a simulated MRT ride when triggered from the debug button — see
    /// `ContentView+DebugSimulate.swift`. Compiled out of release builds entirely.
    @State var debugTrainSimulator = DebugTrainSimulator()
    /// Map centre before a debug run. Start and exit framing include it. See `Debug.md`.
    @State var debugSimAnchor: CLLocationCoordinate2D?
    /// True from a debug run's exit until its framing move lands. `recenterHome()` returns early.
    @State var debugSimHoldsCamera = false
    #endif
    /// Identifies the transition `beginCameraTransition` most recently started. Changing it
    /// stops any running transition. See `Commute.md`.
    @State var cameraTransitionToken = 0

    /// Inputs that return the camera to its resting position.
    /// `hasUserLocation` is a Bool, not the coordinate, so only acquiring a fix re-centres
    /// the map. Keying on the live coordinate would re-centre on every step the passenger takes.
    private struct HomeTrigger: Equatable {
        let hasUserLocation: Bool
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        let hasRoute: Bool
    }

    static let manilaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
    )
    /// Accuracy circle is hidden when `horizontalAccuracy` is at or below this value.
    /// At 20 m the circle is smaller than the puck on screen and carries no information.
    static let accuracyCircleThresholdMeters: CLLocationAccuracy = 20
    /// Maximum distance from the user to the route origin that allows starting Commute Mode.
    /// Beyond this the passenger is too far from the first stop to navigate from it.
    static let commuteStartRadiusMeters: Double = 500

    /// True when the user is within `commuteStartRadiusMeters` of the current route's origin.
    /// Drives the "USE THIS ROUTE" button — hidden when the user is not near the start.
    var canStartCommute: Bool {
        guard let userLoc = routeStore.userLocation,
              let firstLeg = routeStore.routeResult?.legs.first else { return false }
        let originCoord: Coordinates
        if firstLeg.fromStation.isPinnedLocation {
            guard let pinned = routeStore.originCoordinate else { return false }
            originCoord = pinned
        } else {
            originCoord = firstLeg.fromStation.coordinates
        }
        let user   = CLLocation(latitude: userLoc.lat,    longitude: userLoc.lng)
        let origin = CLLocation(latitude: originCoord.lat, longitude: originCoord.lng)
        return user.distance(from: origin) <= Self.commuteStartRadiusMeters
    }

    var body: some View {
        #if DEBUG
        let _ = logBodyReevaluationIfTransitioning()
        #endif
        // Read here, not inside the map content: SwiftUI evaluates the `MapReader` closure
        // outside the observation scope of `body`, so a read there never triggers a redraw.
        let revealedFraction = routeDrawAnimator.revealedFraction
        let choiceFrame = routeChoiceFrame(revealedFraction: revealedFraction)
        MapReader { proxy in
            Map(position: $mapPosition) {
                if showsRouteChoice {
                    routeChoiceMapContent(choiceFrame, legColor: routeStore.legColor, onSelect: selectRouteFromAnnotation)
                } else if let result = routeStore.routeResult, let geo = geometry(for: result) {
                    // ── Polylines — one per RouteLeg ─────────────────────────────
                    // In Commute Mode the line shows only what's left. See `Commute.md`.
                    ForEach(Array(result.legs.enumerated()), id: \.element.id) { index, leg in
                        // Precomputed, not mapped here: this closure re-runs on every
                        // body pass, and walk legs carry hundreds of MKDirections points.
                        let coords = geo.polylines[leg.id] ?? []
                        if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index < currentIndex {
                            completedLegPolylineContent(leg: leg, coords: coords)
                        } else if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index == currentIndex {
                            currentLegPolylineContent(
                                leg: leg, coords: coords, passenger: displayedPuckCoordinate,
                                geometry: geo, walkGridStep: walkGridStep, color: routeStore.legColor(leg))
                        } else {
                            // Not commuting: draw the route on progressively rather than
                            // dropping the whole polyline in at once.
                            let revealed = isCommuting ? coords
                                : geo.revealedCoordinates(leg: leg.id, fraction: revealedFraction)
                            // This leg's own reveal may finish before the route's overall
                            // fraction reaches 1 — each leg regains its cased look as soon
                            // as its own coordinates stop growing, not only once every leg
                            // in the route has.
                            let isAnimating = !isCommuting && revealed.count < coords.count
                            // The mask is only valid against the full, untrimmed polyline
                            // it was measured from — never pass it while still animating.
                            routePolylineContent(
                                leg: leg, coords: revealed, isAnimating: isAnimating, color: routeStore.legColor(leg),
                                sharedMask: isAnimating ? nil : geo.sharedWithNextMask(leg: leg.id))
                        }
                    }
                    // Station connectors draw once per station, not once per leg.
                    let firstDrawnLeg = isCommuting ? min(commuteEngine?.currentLegIndex ?? 0, result.legs.count) : 0
                    stationAccessConnectors(legs: result.legs[firstDrawnLeg...])
                    // ── Destination pin ──────────────────────────────────────────
                    if let last = result.legs.last {
                        let destLabel = last.line == "ACCESS_WALK" ? "" : last.toStation.shortName
                        let point = last.toStation.accessPoint(
                            kind: .both, direction: nil, nearestTo: last.fromStation.coordinates)
                        Annotation(destLabel, coordinate: CLLocationCoordinate2D(
                            latitude: point.lat, longitude: point.lng
                        ), anchor: .bottom) {
                            DestinationPin()
                                .shadow(color: .black.opacity(0.3), radius: 2)
                        }
                    }
                    // ── Transfer dots — start of every leg whose mode differs from the previous leg ──
                    // (user dot is added outside this branch — it shows with or without a route)
                    ForEach(result.modeChangeLegs) { leg in
                        let point = leg.fromStation.accessPoint(
                            kind: .both, direction: nil, nearestTo: leg.toStation.coordinates)
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: point.lat, longitude: point.lng
                        )) {
                            TransferNode()
                        }
                    }
                }
                // ── GPS accuracy circle ──────────────────────────────────────────
                // Radius equals `horizontalAccuracy`, same as the Maps app. Hidden
                // while commuting — see `Commute.md`.
                if isOnScreen, !isCommuting, let userCoord = routeStore.userLocation,
                   let radius = displayedAccuracyRadius {
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: userCoord.lat, longitude: userCoord.lng),
                        radius: radius
                    )
                    .foregroundStyle(Color.tangerine.opacity(0.12))
                    .stroke(Color.tangerine.opacity(0.30), lineWidth: 1)
                }
                // ── The passenger ───────────────────────────────────────────────
                // MapKit's own dot outside commute; a route-snapped `Annotation` during
                // commute. See `Commute.md`.
                if isOnScreen {
                    let snappedPuck = isCommuting && commuteEngine?.snappedLocation != nil
                        ? displayedPuckCoordinate : nil
                    // One `UserAnnotation` at a fixed tree position, hidden by opacity. Two
                    // swapped instances share MapKit's single user-location view, which can
                    // keep the visible content after a second commute and draw two pucks.
                    UserAnnotation { userLocation in
                        PassengerPuck(speed: userLocation.location?.speed)
                            .opacity(snappedPuck == nil ? 1 : 0)
                    }
                    if let snappedPuck {
                        // Drawn at the interpolator's 30 Hz glide position, the same
                        // coordinate the polyline trims at — see `PuckGlideInterpolator`.
                        Annotation("", coordinate: snappedPuck) {
                            PassengerPuck(speed: routeStore.userSpeed)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .ignoresSafeArea()
            // Hides establishment names and icons. Road and place names still show.
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // Long-press on the map: the first press sets origin, later presses set destination.
            // Attach it above the `.safeAreaInset` calls. Below them the hit region covers both
            // panels and stops the route-detail leg list from scrolling.
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard value.first == true else { return }
                        if let cgPoint = value.second?.startLocation,
                           let clCoord = proxy.convert(cgPoint, from: .local) {
                            handleMapLongPress(at: Coordinates(
                                lat: clCoord.latitude, lng: clCoord.longitude))
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { handleRouteTap(at: $0.location, proxy: proxy) }
            )
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraSettled(distance: context.camera.distance)
                recordObservedCamera(context.camera)
                #if DEBUG
                if !isCommuting, !debugTrainSimulator.isBusy { debugSimAnchor = context.region.center }
                #endif
            }
            .onAppear { mapProxy = proxy }
        }
        #if DEBUG
        .overlay(alignment: .topTrailing) { debugSimulateButton }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            // Dropped entirely in Commute Mode — the map reads as full-bleed with
            // just the bottom card, matching the reference UI.
            if !isCommuting {
                CommuteSearchPanel(
                    routeStore: routeStore,
                    originText: $originText,
                    destinationText: $destinationText,
                    focusedField: $focusedField,
                    namespace: searchNS,
                    showSearchProgress: showSearchProgress,
                    onReset: resetAll,
                    onSearch: search,
                    onSwap: swapOriginDestination,
                    onClearOrigin: clearOrigin,
                    onClearDestination: clearDestination,
                    onSelectOrigin: selectOrigin,
                    onSelectDestination: selectDestination
                )
                .padding(CommuteSearchPanel.panelPadding)
                    // The measurement is published from the card/pill itself, not from
                    // here — see `measuresVisibleTop`. Reading the padded panel's own
                    // frame would fold the suggestion list into it.
                    .onPreferenceChange(VisibleTopKey.self) { newValue in
                        #if DEBUG
                        print("[CameraDebug] visibleTop \(visibleTop) -> \(newValue) t=\(Date().timeIntervalSince1970)")
                        #endif
                        visibleTop = newValue; placeRouteBubble()
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !routeStore.routeOptions.isEmpty {
                RouteChoiceSheet(
                    options: routeStore.routeOptions,
                    selectedID: $routeChoice.selectedID,
                    isDetailExpanded: $routeChoice.isDetailExpanded,
                    canStartCommute: canStartCommute,
                    onUse: { startCommute(with: $0) }, legColor: routeStore.legColor
                )
                .padding(.horizontal)
                .padding(.bottom)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: VisibleBottomKey.self,
                                               value: geo.frame(in: .global).minY)
                    }
                )
                .onPreferenceChange(VisibleBottomKey.self) { newValue in
                    #if DEBUG
                    print("[CameraDebug] visibleBottom(routeResults) \(visibleBottom) -> \(newValue) t=\(Date().timeIntervalSince1970)")
                    #endif
                    visibleBottom = newValue; placeRouteBubble()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DesignTokens.Motion.cardEnter, value: routeStore.routeOptions.isEmpty)
        .commuteSheet(
            isActive: isCommuting && session.isLoggedIn,
            cameraMode: $commuteCameraMode,
            isFollowing: $isFollowingPassenger,
            onRouteOverview: showRouteOverview,
            onSheetTopChange: followSheetTop,
            card: commuteCard
        )
        .toolbarVisibility(isCommuting ? .hidden : .visible, for: .tabBar)
        .savedPlaceDragHost()
        // Auto-set origin: fills the empty origin field on the first GPS fix. See
        // `Commute.md`.
        .onChange(of: routeStore.userLocation, initial: true) { _, newValue in
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
        // The one seam that notices the app came back from the background at all —
        // see `autoSetOriginText`'s and `wasBackgrounded`'s doc comments.
        .onChange(of: scenePhase) { _, new in
            if new == .background {
                wasBackgrounded = true
                saveCommute()
                return
            }
            guard new == .active, wasBackgrounded, !isCommuting else { return }
            wasBackgrounded = false
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
        // Elapsed time keeps moving even between sparse GPS fixes — standing on a
        // platform shouldn't freeze "how late am I" until the next one arrives.
        .task(id: isCommuting) {
            guard isCommuting else { return }
            while !Task.isCancelled {
                commuteEngine?.recomputeOnTimeStatus(now: .now)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Dead-reckoning tick: runs at 1 Hz while commuting. See `Commute.md`.
        .task(id: isCommuting) {
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
        // Continuous camera follow, ticking at the puck's own 30 Hz cadence instead
        // of writing a new camera position once per GPS fix. See `Commute.md`.
        .task(id: isCommuting) {
            guard isCommuting else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
                guard !Task.isCancelled, isCommuting else { return }
                advanceSmoothedRouteHeading()
                refreshWalkGridStepIfStale(now: .now)
                guard isFollowingPassenger, !isCameraTransitioning, !isEnteringCommute else { continue }
                updateCommuteCamera(.followTick)
            }
        }
        // While free-panning the switch changes the camera in place and keeps its centre.
        .onChange(of: commuteCameraMode) { oldValue, newValue in
            #if DEBUG
            print("[CameraDebug] commuteCameraMode \(oldValue) -> \(newValue) following=\(isFollowingPassenger) t=\(Date().timeIntervalSince1970)")
            #endif
            refreshWalkGridStep(now: .now)
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
        // Rebuild the cached geometry whenever the route itself changes — identity is
        // the leg list, since RouteLeg.id is a fresh UUID per computed route.
        .onChange(of: routeStore.routeResult?.legs.map(\.id), initial: true) { _, _ in
            routeGeometry = routeStore.routeResult.flatMap(RouteGeometry.init)
        }
        // Route choice: per-option map data, the active route, and the camera refit
        // after the sheet changes height. See `ContentView+RouteChoice.swift`.
        .onChange(of: routeChoiceKey, initial: true) { _, _ in syncRouteChoice() }
        .onChange(of: routeChoice.selectedID) { _, _ in previewSelectedRoute(); placeRouteBubble() }
        .onChange(of: routeChoice.isDetailExpanded) { _, _ in
            Task { await refitForDetailToggle() }
        }
        // Live position for as long as the map is on screen — for the resting camera
        // and the search fields. The dot is MapKit's own (see `UserAnnotation` above)
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


    // MARK: - Actions

    /// Runs the search, then frames the result.
    /// Chains the camera fit here rather than observing `routeResult`, so a failed search
    /// leaves the camera where the passenger left it.
    private func search() {
        focusedField = nil
        routeDrawAnimator.prepareForNewRoute()
        Task {
            await routeStore.calculateRoute()
            await fitToRouteIfSuccessful()
        }
    }

    private func selectOrigin(_ suggestion: LocationSuggestion) {
        switch suggestion {
        case .station(let station):
            routeStore.confirmOriginStation(station)
            originText = station.name
            focusedField = .destination
        case .address(let completion):
            Task {
                if let name = await routeStore.confirmOriginAddress(completion) {
                    originText = name
                    focusedField = .destination
                }
            }
        }
    }

    private func selectDestination(_ suggestion: LocationSuggestion) {
        switch suggestion {
        case .station(let station):
            routeStore.confirmDestinationStation(station)
            destinationText = station.name
            focusedField = nil
        case .address(let completion):
            Task {
                if let name = await routeStore.confirmDestinationAddress(completion) {
                    destinationText = name
                    focusedField = nil
                }
            }
        }
    }

    private func clearOrigin() {
        originText = ""
        routeStore.originID = ""
        routeStore.originCoordinate = nil
        routeStore.confirmedOriginLabel = nil
        routeStore.lastOriginQuery = ""
        routeStore.originDebounce?.cancel()
        routeStore.originSuggestions = []
        routeStore.showOriginSuggestions = false
    }

    private func clearDestination() {
        destinationText = ""
        routeStore.destinationID = ""
        routeStore.destinationCoordinate = nil
        routeStore.confirmedDestLabel = nil
        routeStore.lastDestQuery = ""
        routeStore.destDebounce?.cancel()
        routeStore.destSuggestions = []
        routeStore.showDestSuggestions = false
    }

    private func resetAll() {
        focusedField = nil
        clearOrigin(); clearDestination()
        routeStore.routeResult = nil
        routeStore.routeOptions = []
        routeStore.errorMessage = nil
        // Allow the next GPS fix to re-fill the origin field after a full reset.
        hasAutoSetOrigin = false
        // Back to the passenger (or the Manila default), strip-centred. The HomeTrigger
        // task fires too when a route was cleared; calling here as well covers Reset with
        // no route on screen, and the two are idempotent.
        recenterHome()
    }

    // MARK: Commute Mode

    /// Enters Commute Mode for `option` as of `startedAt`. Shared by `startCommute` and the
    /// launch restore in `ContentView+CommutePersistence.swift`. See `Commute.md`.
    func enterCommuteMode(with option: RouteOption, startedAt: Date) {
        #if DEBUG
        print("[CameraDebug] startCommute BEGIN mapPositionWasRegion=\(mapPosition.region != nil) visibleTop=\(visibleTop) visibleBottom=\(visibleBottom) userLocation=\(String(describing: routeStore.userLocation)) commuteCameraMode=\(commuteCameraMode) t=\(startedAt.timeIntervalSince1970)")
        #endif
        // Holds the follow loop off until the `.fit` correction below has had time to
        // land, so it can't restart that glide mid-flight. See `Commute.md`.
        isEnteringCommute = true
        commuteEntryToken += 1
        let entryToken = commuteEntryToken
        lastCommuteCameraCenter = nil
        lastCommuteCameraDistance = nil
        lastCommuteCameraPitch = nil
        lastCommuteCameraHeading = nil
        smoothedRouteHeading = nil
        lastHeadingSample = nil
        stripBottomEase = nil
        commuteStripBottom = 0
        withAnimation(DesignTokens.Motion.morph) {
            routeStore.selectRoute(option)
            commuteStartedAt = startedAt
            commuteEngine = CommuteProgressEngine(result: option.result, startedAt: startedAt)
            isCommuting = true
        }
        // A new commute always starts attached, whatever the last one ended on.
        isFollowingPassenger = true
        // No top panel during Commute Mode — clears whatever the search pill last
        // measured, so `visibleStrip` doesn't reserve space for a panel that's gone.
        visibleTop = 0
        positionResolver.reset()
        puckInterpolator.reset()
        rerouteMonitor.reset()
        // Seeds the engine with wherever the passenger already is, instead of waiting
        // for the next GPS fix. See `Commute.md`.
        if let userLocation = routeStore.userLocation {
            positionResolver.recordFix(userLocation, speed: routeStore.userSpeed, at: startedAt)
            commuteEngine?.update(location: userLocation, now: startedAt)
        }
        // Glides from wherever the camera already sat to the ride's starting pose.
        // See `Commute.md`.
        #if DEBUG
        if !routeStore.isLocationSimulated { updateCommuteCamera(.start) }
        #else
        updateCommuteCamera(.start)
        #endif
        Task {
            try? await Task.sleep(for: .seconds(DesignTokens.Motion.cameraFitDuration))
            guard commuteEntryToken == entryToken else { return }
            isEnteringCommute = false
        }
        #if DEBUG
        print("[CameraDebug] startCommute END t=\(Date().timeIntervalSince1970)")
        #endif
    }

    #if DEBUG
    // Temporary — remove once the 2D/3D transition stutter is confirmed fixed. Proves
    // whether `body` (and so the `Map` value it produces) re-evaluates during a
    // transition for reasons other than the camera write itself.
    private func logBodyReevaluationIfTransitioning() {
        if isCameraTransitioning {
            print("[CameraDebug] body re-evaluated while transitioning t=\(Date().timeIntervalSince1970)")
        }
    }
    #endif

    /// Leaves Commute Mode and returns to the blank search state.
    /// Does not morph back into a route-option card, because `selectRoute` already emptied
    /// `routeOptions`. Internal rather than private — see `startCommute`.
    func endCommute(reason: CommuteEndReason) {
        logCommuteEnd(reason)
        #if DEBUG
        endDebugSimulationIfActive()
        #endif
        ActiveCommuteStore.clear()
        withAnimation(DesignTokens.Motion.morph) {
            isCommuting = false
            commuteEngine = nil
            commuteStartedAt = nil
            arrivedAt = nil
        }
        endLiveActivity()
        positionResolver.reset()
        puckInterpolator.reset()
        rerouteMonitor.reset()
        commuteCameraMode = .twoD
        resetAll()
    }

    /// Feeds the latest fix to `rerouteMonitor` and starts `CommuteRerouter` if it fires.
    /// Only a walk leg is eligible; the monitor itself no-ops otherwise. The cooldown arms
    /// only once the reroute actually lands — a failed attempt (offline, rate-limited)
    /// retries on the very next sustained deviation instead. See `Commute.md`.
    private func evaluateReroute(at location: Coordinates, now: Date) {
        guard let engine = commuteEngine, let leg = currentCommuteLeg(for: engine) else { return }
        let shouldReroute = rerouteMonitor.evaluate(
            isWalkingLeg: leg.mode == .walk,
            offRouteMeters: engine.currentLegOffRouteMeters,
            routeAheadBearing: engine.currentLegAheadBearing,
            speed: routeStore.userSpeed,
            course: routeStore.userCourse,
            now: now
        )
        guard shouldReroute else { return }
        let legIndex = engine.currentLegIndex
        Task {
            let succeeded = await routeStore.rerouteCurrentWalkLeg(from: location, legIndex: legIndex, engine: engine)
            if succeeded {
                saveCommute()
                rerouteMonitor.armCooldown(now: Date())
            }
        }
    }

    private func swapOriginDestination() {
        let tempText  = originText
        let tempID    = routeStore.originID
        let tempCoord = routeStore.originCoordinate
        let tempLabel = routeStore.confirmedOriginLabel

        originText              = destinationText
        routeStore.originID             = routeStore.destinationID
        routeStore.originCoordinate     = routeStore.destinationCoordinate
        routeStore.confirmedOriginLabel = routeStore.confirmedDestLabel

        destinationText          = tempText
        routeStore.destinationID         = tempID
        routeStore.destinationCoordinate = tempCoord
        routeStore.confirmedDestLabel    = tempLabel

        // Normalise virtual IDs after the swap
        if routeStore.originID == RouteRequest.virtualDestID       { routeStore.originID = RouteRequest.virtualOriginID }
        if routeStore.destinationID == RouteRequest.virtualOriginID { routeStore.destinationID = RouteRequest.virtualDestID }

        routeStore.originDebounce?.cancel()
        routeStore.destDebounce?.cancel()
        routeStore.lastOriginQuery       = ""
        routeStore.lastDestQuery         = ""
        routeStore.showOriginSuggestions = false
        routeStore.showDestSuggestions   = false
        routeStore.originSuggestions     = []
        routeStore.destSuggestions       = []
    }

    /// Long-press handler: sets the tapped coordinate as origin if unset, destination otherwise.
    private func handleMapLongPress(at coord: Coordinates) {
        if routeStore.originID.isEmpty {
            routeStore.setOriginCoordinate(coord)
            originText = "Pinned Location"
            routeStore.showOriginSuggestions = false
        } else {
            routeStore.setDestinationCoordinate(coord)
            destinationText = "Pinned Location"
            routeStore.showDestSuggestions = false
        }
    }

    // Mode styling lives in extension TransportMode (DesignTokens.swift).
}
