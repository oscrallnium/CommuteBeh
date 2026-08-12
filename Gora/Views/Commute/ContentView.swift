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

    // MARK: Commute Mode
    //
    // `commuteEngine` is non-nil exactly when `isCommuting` is true.
    @State var isCommuting = false
    @State var commuteEngine: CommuteProgressEngine?
    @State private var commuteStartedAt: Date?
    @State var commuteCameraMode: CommuteCameraMode = .twoD
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

    var body: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                if let result = routeStore.routeResult, let geo = geometry(for: result) {
                    // ── Polylines — one per RouteLeg ─────────────────────────────
                    ForEach(result.legs) { leg in
                        // Precomputed, not mapped here: this closure re-runs on every
                        // body pass, and walk legs carry hundreds of MKDirections points.
                        let coords = geo.polylines[leg.id] ?? []
                        // A walk leg with no geometry is one MKDirections couldn't route.
                        // It draws nothing on purpose — see WalkRouteRefiner. Never fall
                        // back to connecting the endpoints.
                        if coords.count < 2 {
                            EmptyMapContent()
                        } else if leg.line == "ACCESS_WALK" {
                            // Access/egress walk: dashed gray to match TransportModeConfig.mapLineDash
                            MapPolyline(coordinates: coords)
                                .stroke(.gray.opacity(0.6),
                                        style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
                        } else {
                            MapPolyline(coordinates: coords)
                                .stroke(leg.mode.color, lineWidth: leg.mode.lineWidth)
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
                        cameraMode: $commuteCameraMode,
                        onEndCommute: endCommute
                    )
                    .padding(.horizontal)
                    .padding(.bottom)
                } else if !routeStore.routeOptions.isEmpty {
                    RouteResultsPanel(
                        options: routeStore.routeOptions,
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
            // Live leg progress, active only during Commute Mode. Every fix also re-centres
            // the camera on the engine's road-snapped position.
            .onChange(of: routeStore.userLocation) { _, newValue in
                guard isCommuting, let newValue else { return }
                commuteEngine?.update(location: newValue)
                updateCommuteCamera()
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
            .onChange(of: commuteCameraMode) { _, _ in updateCommuteCamera() }
            .onChange(of: commuteEngine?.currentLegIndex) { _, _ in updateCommuteCamera() }
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
        // Back to the passenger (or the Manila default), strip-centred. The HomeTrigger
        // task fires too when a route was cleared; calling here as well covers Reset with
        // no route on screen, and the two are idempotent.
        recenterHome()
    }

    // MARK: Commute Mode

    /// Commits to `option` and enters Commute Mode.
    /// Keeps the card morph, the route selection, and the camera change in one
    /// `withAnimation` transaction so they land in the same visual beat.
    private func startCommute(with option: RouteOption) {
        let startedAt = Date()
        withAnimation(DesignTokens.Motion.morph) {
            routeStore.selectRoute(option)
            commuteStartedAt = startedAt
            commuteEngine = CommuteProgressEngine(result: option.result, startedAt: startedAt)
            isCommuting = true
        }
        updateCommuteCamera()
    }

    /// Leaves Commute Mode and returns to the blank search state.
    /// Does not morph back into a route-option card, because `selectRoute` already emptied
    /// `routeOptions`.
    private func endCommute() {
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
