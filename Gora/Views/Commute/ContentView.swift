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
    @State private var originText = ""
    @State private var destinationText = ""
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

    // MARK: Commute Mode
    //
    // `commuteEngine` is non-nil exactly when `isCommuting` is true.
    @State var isCommuting = false
    @State var commuteEngine: CommuteProgressEngine?
    @State private var commuteStartedAt: Date?
    /// When the previous GPS fix landed, so the next one's camera glide can be paced to
    /// the real gap between fixes instead of a fixed duration. `nil` before the first fix.
    @State private var lastLocationFixAt: Date?
    @State var commuteCameraMode: CommuteCameraMode = .twoD
    /// True while a 2D/3D camera transition loop is in flight.
    @State var isCameraTransitioning = false
    /// Whether the camera stays locked to the passenger. While true the follow loop rewrites the
    /// camera every tick, which discards any pan, so a passenger turns this off to move the map.
    @State private var isFollowingPassenger = true
    #if DEBUG
    /// Drives a simulated MRT ride when triggered from the debug button — see
    /// `ContentView+DebugSimulate.swift`. Compiled out of release builds entirely.
    @State var debugTrainSimulator = DebugTrainSimulator()
    #endif
    /// Identifies the glide `beginCameraTransition()` most recently started. Its completion
    /// callback compares its own copy against this before clearing `isCameraTransitioning`,
    /// so a second toggle mid-glide can't have the first glide's late completion clear the
    /// flag out from under the new one.
    @State private var cameraTransitionToken = 0
    /// Snapshot of `livePassengerCoordinate` taken when a camera transition begins, and
    /// substituted for it while one is in flight — see `polylineTrimCoordinate`.
    /// `isCameraTransitioning` only ever gated the camera *position* write; a GPS fix
    /// landing mid-transition still moved the live route polyline's trim point, rebuilding
    /// the Map's content underneath the still-running glide.
    @State var frozenTrimCoordinate: CLLocationCoordinate2D?
    /// Shared with `RouteOptionCard` and `CommuteModeView` so the selected card morphs into
    /// the commute card. Both ends tag their shape `"commute-card"`.
    @Namespace private var commuteNS

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
        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
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
        MapReader { proxy in
            Map(position: $mapPosition) {
                if let result = routeStore.routeResult, let geo = geometry(for: result) {
                    // ── Polylines — one per RouteLeg ─────────────────────────────
                    // In Commute Mode the line only ever shows what's left: nothing for
                    // a leg already ridden, the live-trimmed leg for the one the
                    // passenger is on, the full leg for everything still ahead. Outside
                    // Commute Mode every leg draws in full, as the search preview always has.
                    ForEach(Array(result.legs.enumerated()), id: \.element.id) { index, leg in
                        // Precomputed, not mapped here: this closure re-runs on every
                        // body pass, and walk legs carry hundreds of MKDirections points.
                        let coords = geo.polylines[leg.id] ?? []
                        if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index < currentIndex {
                            EmptyMapContent()
                        } else if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index == currentIndex {
                            currentLegPolylineContent(leg: leg, coords: coords, passenger: polylineTrimCoordinate)
                        } else {
                            routePolylineContent(leg: leg, coords: coords)
                        }
                    }
                    // ── Origin pin ───────────────────────────────────────────────
                    // Drawn at the station's nearest access point, not its raw coordinate,
                    // which is a routing position and can sit in the middle of the road.
                    // `accessPoint` falls back to the centroid when no doors are recorded.
                    if let first = result.legs.first {
                        let point = first.fromStation.accessPoint(
                            kind: .both, direction: nil, nearestTo: first.toStation.coordinates)
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: point.lat, longitude: point.lng
                        )) {
                            ZStack {
                                Circle().fill(.green).frame(width: 16, height: 16)
                                Circle().stroke(.white, lineWidth: 2.5).frame(width: 16, height: 16)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 2)
                        }
                    }
                    // ── Destination pin ──────────────────────────────────────────
                    if let last = result.legs.last {
                        let destLabel = last.line == "ACCESS_WALK" ? "" : last.toStation.shortName
                        let point = last.toStation.accessPoint(
                            kind: .both, direction: nil, nearestTo: last.fromStation.coordinates)
                        Annotation(destLabel, coordinate: CLLocationCoordinate2D(
                            latitude: point.lat, longitude: point.lng
                        )) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(.red)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                    // ── Transfer dots — boarding station of every non-access leg ──
                    // (user dot is added outside this branch — it shows with or without a route)
                    ForEach(result.legs.dropFirst().filter { $0.line != "ACCESS_WALK" }) { leg in
                        let point = leg.fromStation.accessPoint(
                            kind: .both, direction: nil, nearestTo: leg.toStation.coordinates)
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: point.lat, longitude: point.lng
                        )) {
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(leg.mode.color, lineWidth: 2))
                                .shadow(color: .black.opacity(0.2), radius: 1)
                        }
                    }
                }
                // ── GPS accuracy circle ──────────────────────────────────────────
                // Radius equals `horizontalAccuracy` in metres — the same semantics
                // as the Maps app blue circle. Drawn below the puck so the dot stays
                // on top. `displayedAccuracyRadius` is an animated copy updated with
                // easeInOut in the `.onChange` below, so the circle resizes smoothly.
                if isOnScreen, let userCoord = routeStore.userLocation,
                   let radius = displayedAccuracyRadius {
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: userCoord.lat, longitude: userCoord.lng),
                        radius: radius
                    )
                    .foregroundStyle(.blue.opacity(0.12))
                    .stroke(.blue.opacity(0.30), lineWidth: 1)
                }
                // ── The passenger ───────────────────────────────────────────────
                // `UserAnnotation`, not `Annotation`, whose coordinate does not animate and
                // makes the dot jump between fixes. Gating on `isOnScreen` removes it from
                // the content, which is the only way to stop MapKit's location feed.
                if isOnScreen {
                    UserAnnotation { userLocation in
                        PassengerPuck(speed: userLocation.location?.speed)
                    }
                }
            }
            .ignoresSafeArea()
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
                        .onPreferenceChange(VisibleTopKey.self) { visibleTop = $0 }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCommuting, let commuteEngine, let result = routeStore.routeResult {
                    CommuteModeView(
                        result: result,
                        engine: commuteEngine,
                        destinationText: destinationText,
                        morphNS: commuteNS,
                        onEndCommute: endCommute
                    )
                    .padding(.horizontal)
                    .padding(.bottom)
                    // Anchored to the card's own top edge, not the map's — `alignmentGuide`
                    // swaps which edge of *this* overlay lines up with the card's top, so
                    // the row sits entirely above the card instead of over its first rows.
                    // That keeps it in place whether the card is compact or expanded.
                    .overlay(alignment: .top) {
                        HStack(alignment: .bottom, spacing: 8) {
                            if let leg = currentCommuteLeg(for: commuteEngine) {
                                CommuteSpeedReadout(
                                    speedMetersPerSecond: routeStore.userSpeed,
                                    metersRemaining: commuteEngine.metersRemainingOnCurrentLeg,
                                    nextStopName: leg.toStation.shortName
                                )
                            }
                            Spacer(minLength: 8)
                            CommuteMapControls(cameraMode: $commuteCameraMode,
                                               isFollowing: $isFollowingPassenger)
                        }
                        // Matches `CommuteModeView`'s own internal padding, so this row's
                        // leading and trailing edges line up with the card's text below it
                        // instead of the card's outer edge, 18pt further out.
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .alignmentGuide(.top) { $0[.bottom] }
                    }
                } else if !routeStore.routeOptions.isEmpty {
                    RouteResultsPanel(
                        options: routeStore.routeOptions,
                        canStartCommute: canStartCommute,
                        morphNS: commuteNS,
                        onSelect: { startCommute(with: $0) },
                        onPreview: { routeStore.previewRoute($0) }
                    )
                    .padding(.horizontal)
                    .padding(.bottom)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: VisibleBottomKey.self,
                                                   value: geo.frame(in: .global).minY)
                        }
                    )
                    .onPreferenceChange(VisibleBottomKey.self) { visibleBottom = $0 }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(DesignTokens.Motion.cardEnter, value: routeStore.routeOptions.isEmpty)
            // Auto-set origin: when the first GPS fix arrives and origin is still empty,
            // fill it with the user's position so they can search immediately without
            // typing. `hasAutoSetOrigin` prevents subsequent fixes from overwriting an
            // origin the user has since edited or cleared manually.
            .onChange(of: routeStore.userLocation, initial: true) { _, newValue in
                guard !hasAutoSetOrigin,
                      let newValue,
                      routeStore.originID.isEmpty,
                      !isCommuting else { return }
                hasAutoSetOrigin = true
                routeStore.setOriginCoordinate(newValue)
                routeStore.confirmedOriginLabel = "My Location"
                originText = "My Location"
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
            // Live leg progress, active only during Commute Mode. Progress tracking (leg
            // index, ETA, snapped position) always stays live; only the camera re-centre
            // that follows it is gated on `isFollowingPassenger` — a passenger who has
            // panned away to look ahead should not have every fix drag the map back,
            // paced to the time since the previous fix so consecutive glides hand off
            // instead of decelerating to a stop between fixes — see `CameraFollowTrigger.location`.
            .onChange(of: routeStore.userLocation) { _, newValue in
                guard isCommuting, let newValue else { return }
                let now = Date()
                let elapsed = lastLocationFixAt.map { now.timeIntervalSince($0) }
                    ?? DesignTokens.Motion.locationFollowMinDuration
                lastLocationFixAt = now
                commuteEngine?.update(location: newValue, now: now)
                #if DEBUG
                print("[CameraDebug] userLocation fix following=\(isFollowingPassenger) transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                // A transition glide (mode switch, re-attach, or commute start) owns the
                // camera until it lands — the same rule the heading loop follows — so a
                // fix landing mid-glide doesn't cut it off with a competing animation.
                guard isFollowingPassenger, !isCameraTransitioning else { return }
                updateCommuteCamera(.location(elapsedSinceLastFix: elapsed))
            }
            // A train leg's track-snap resolves asynchronously (`TrackSnapper` is an
            // actor), so it can land after the fix above already moved the camera on the
            // raw or previous position. This corrects that glide's endpoint once the true
            // snap is in. Gated to train legs — every other mode's snap is synchronous
            // within `update(location:)`, so the change above already reflects it and
            // firing here too would just re-animate to the same spot.
            .onChange(of: commuteEngine?.snappedLocation) { _, _ in
                #if DEBUG
                print("[CameraDebug] snappedLocation changed transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                guard isCommuting, isFollowingPassenger, !isCameraTransitioning,
                      let engine = commuteEngine, let leg = currentCommuteLeg(for: engine),
                      leg.mode == .train
                else { return }
                updateCommuteCamera(.locationCorrection)
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
            // Skipped while free-panning: a mode switch is not a request to snap back to
            // the passenger, and the passenger's own `beginCameraTransition()` call in
            // `startCommute` and the re-attach handler below cover every case where a
            // camera move on mode-switch actually is wanted.
            .onChange(of: commuteCameraMode) { oldValue, newValue in
                #if DEBUG
                print("[CameraDebug] commuteCameraMode \(oldValue) -> \(newValue) following=\(isFollowingPassenger) t=\(Date().timeIntervalSince1970)")
                #endif
                guard isFollowingPassenger else { return }
                beginCameraTransition(fromPitch: oldValue.pitch, fromDistance: oldValue.distance)
            }
            .onChange(of: commuteEngine?.currentLegIndex) { _, _ in
                #if DEBUG
                print("[CameraDebug] currentLegIndex changed transitioning=\(isCameraTransitioning) t=\(Date().timeIntervalSince1970)")
                #endif
                guard isFollowingPassenger, !isCameraTransitioning else { return }
                updateCommuteCamera(.fit)
            }
            // Re-attaching glides back to the passenger and holds the follow loop off until the
            // glide lands. Detaching writes nothing, so the map stays where the passenger left it.
            .onChange(of: isFollowingPassenger) { _, following in
                #if DEBUG
                print("[CameraDebug] isFollowingPassenger -> \(following) t=\(Date().timeIntervalSince1970)")
                #endif
                guard following else { return }
                beginCameraTransition()
            }
            // Rebuild the cached geometry whenever the route itself changes — identity is
            // the leg list, since RouteLeg.id is a fresh UUID per computed route.
            .onChange(of: routeStore.routeResult?.legs.map(\.id), initial: true) { _, _ in
                routeGeometry = routeStore.routeResult.flatMap(RouteGeometry.init)
            }
            // Live position for as long as the map is on screen — for the resting camera
            // and the search fields. The dot is MapKit's own (see `UserAnnotation` above)
            // and does not come from here.
            .onAppear {
                routeStore.startTrackingUserLocation()
                isOnScreen = true
                mapProxy = proxy
            }
            // The tab bar makes this fire on every tab switch, which is exactly when both
            // location feeds should stop.
            .onDisappear {
                routeStore.stopTrackingUserLocation()
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
                await DebugRouteSeed.searchIfRequested(on: routeStore)
                await fitToRouteIfSuccessful()
            }
            #endif
        }
    }


    // MARK: - Actions

    /// Runs the search, then frames the result.
    /// Chains the camera fit here rather than observing `routeResult`, so a failed search
    /// leaves the camera where the passenger left it.
    private func search() {
        focusedField = nil
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

    /// Commits to `option` and enters Commute Mode.
    /// Keeps the card morph, the route selection, and the camera change in one
    /// `withAnimation` transaction so they land in the same visual beat.
    ///
    /// Internal rather than private: `ContentView+DebugSimulate` calls this too, to
    /// enter Commute Mode the same way a route-card tap does.
    func startCommute(with option: RouteOption) {
        let startedAt = Date()
        withAnimation(DesignTokens.Motion.morph) {
            routeStore.selectRoute(option)
            commuteStartedAt = startedAt
            commuteEngine = CommuteProgressEngine(result: option.result, startedAt: startedAt)
            isCommuting = true
        }
        // The gap before this commute's first fix isn't a real inter-fix interval —
        // starts the pacing fresh instead of glide-timing off however long selection took.
        lastLocationFixAt = nil
        // A new commute always starts attached, whatever the last one ended on.
        isFollowingPassenger = true
        beginCameraTransition()
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

    /// Moves the camera to the current mode's pose — pitch, distance, and centre.
    /// Bearing tracking is entirely off for the duration: heading is held at whatever
    /// `displayedHeadingDegrees` already holds (see the `newValue == .twoD` branch in
    /// `onChange(of: commuteCameraMode)`, which keeps it pinned to 0 for as long as 2D is
    /// active, since the heading-tracking task below doesn't run then). The heading-
    /// tracking task resumes on its own the moment this glide lands, and corrects the
    /// camera to the live bearing from there.
    ///
    /// `fromPitch`/`fromDistance` are the pose this glide starts from. Pass the old
    /// mode's values from `onChange(of: commuteCameraMode)`; every other caller leaves
    /// them `nil`, which resolves to `commuteCameraMode`'s own (already-current) values
    /// — there is then nothing to interpolate, and this collapses to a single write.
    ///
    /// MapKit's camera animator does not blend a distance change and a pitch change
    /// cleanly within one `withAnimation` transaction — asked for together, it visibly
    /// resolves one before picking up the other. Rather than hand it a single 0.5 s
    /// jump, this ticks its own interpolation loop at the same 30 Hz cadence
    /// `advanceDisplayedHeading()` uses for bearing, writing an eased blend of distance
    /// and pitch together every ~33 ms. Each tick's delta is small enough that MapKit
    /// animates it cleanly, so the two properties move as one continuous descent-and-tilt
    /// instead of MapKit's own two-stage attempt at the same combined change.
    ///
    /// Call this instead of `updateCommuteCamera()` whenever pitch or distance changes,
    /// because the loop writes the whole camera and would otherwise cut the glide short.
    private func beginCameraTransition(fromPitch: Double? = nil, fromDistance: CLLocationDistance? = nil) {
        isCameraTransitioning = true
        frozenTrimCoordinate = livePassengerCoordinate
        cameraTransitionToken += 1
        let token = cameraTransitionToken

        let startPitch = fromPitch ?? commuteCameraMode.pitch
        let startDistance = fromDistance ?? commuteCameraMode.distance
        let targetPitch = commuteCameraMode.pitch
        let targetDistance = commuteCameraMode.distance

        #if DEBUG
        print("[CameraDebug] transition START token=\(token) mode=\(commuteCameraMode) t=\(Date().timeIntervalSince1970)")
        #endif

        Task {
            let startedAt = Date()
            let duration = DesignTokens.Motion.cameraFitDuration
            while true {
                guard cameraTransitionToken == token else {
                    #if DEBUG
                    print("[CameraDebug] transition token=\(token) SKIPPED — superseded by token=\(cameraTransitionToken)")
                    #endif
                    return
                }
                let fraction = duration > 0 ? min(1, Date().timeIntervalSince(startedAt) / duration) : 1
                let eased = Self.easeInOut(fraction)
                updateCommuteCamera(
                    .poseTransition,
                    distanceOverride: startDistance + eased * (targetDistance - startDistance),
                    pitchOverride: startPitch + eased * (targetPitch - startPitch)
                )
                if fraction >= 1 { break }
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
            }
            #if DEBUG
            print("[CameraDebug] transition END token=\(token) t=\(Date().timeIntervalSince1970)")
            #endif
            isCameraTransitioning = false
        }
    }

    /// Smoothstep: eases a 0...1 progress fraction in and out, the same shape
    /// `.easeInOut` gives a `withAnimation` curve, for the transition loop above to
    /// apply by hand to distance and pitch every tick instead of per-frame.
    private static func easeInOut(_ fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Leaves Commute Mode and returns to the blank search state.
    /// Does not morph back into a route-option card, because `selectRoute` already emptied
    /// `routeOptions`. Internal rather than private — see `startCommute`.
    func endCommute() {
        withAnimation(DesignTokens.Motion.morph) {
            isCommuting = false
            commuteEngine = nil
            commuteStartedAt = nil
        }
        resetAll()
    }

    func currentCommuteLeg(for engine: CommuteProgressEngine) -> RouteLeg? {
        guard let result = routeStore.routeResult, result.legs.indices.contains(engine.currentLegIndex)
        else { return nil }
        return result.legs[engine.currentLegIndex]
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
