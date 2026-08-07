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
    @State private var vm = CommuteViewModel()
    @State private var originText = ""
    @State private var destinationText = ""
    @State private var mapPosition: MapCameraPosition = .region(Self.manilaRegion)
    /// Captured once the map appears — see `moveCamera`.
    @State private var mapProxy: MapProxy?
    @State private var showSearchProgress = false
    @FocusState private var focusedField: SearchField?
    @Namespace private var searchNS
    /// Bottom edge of the search panel and top edge of the results panel, in global
    /// (window) coordinates — the strip of map the passenger can actually see.
    ///
    /// Measured directly rather than reconstructed from the two panels' heights plus the
    /// window's safe-area insets. That reconstruction was short by everything it did not
    /// know about: this screen sits inside a `TabView`, and the window's bottom inset is
    /// the home indicator alone — it does not include the tab bar, which on a 402x874
    /// device hid a further 53pt the camera never accounted for. An edge read straight
    /// from the layout cannot be wrong about what is between it and the screen.
    @State private var visibleTop: CGFloat = 0
    @State private var visibleBottom: CGFloat = 0
    /// Map-ready coordinates + bounding box for `vm.routeResult`. See `RouteGeometry`.
    @State private var routeGeometry: RouteGeometry?
    /// Whether this tab is the one on screen. Gates the location dot — see `UserAnnotation`.
    @State private var isOnScreen = false
    private enum SearchField { case origin, destination }

    /// Inputs that should re-frame the camera. Bundled so the debounced fit below has a
    /// single `id` to key on.
    private struct FitTrigger: Equatable {
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        let isLoading: Bool
    }

    /// Inputs that should return the camera to its resting position. `hasRoute` is what
    /// makes Reset re-fire it: clearing `routeResult` flips it back to `false`.
    ///
    /// `hasUserLocation` is a Bool and not the coordinate itself on purpose. The location
    /// feed is live, so the coordinate changes every few metres the passenger walks —
    /// keying on it would re-centre the camera on every one of those, snatching the map
    /// back from anyone who had panned it. What earns a re-centre is *acquiring* a fix
    /// (nil → non-nil), which happens once. `recenterHome` reads the current coordinate
    /// when it runs, so the camera still lands on the up-to-date position.
    private struct HomeTrigger: Equatable {
        let hasUserLocation: Bool
        let visibleTop: CGFloat
        let visibleBottom: CGFloat
        let hasRoute: Bool
    }

    /// Inset the search panel carries inside the top safe area. Added back by
    /// `measuresVisibleTop` so the published edge still describes the panel's outer
    /// boundary even though it is measured from the card within it.
    private static let panelPadding: CGFloat = 16

    private static let manilaRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
    )

    var body: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                if let result = vm.routeResult, let geo = geometry(for: result) {
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
                    if let first = result.legs.first {
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: first.fromStation.coordinates.lat,
                            longitude: first.fromStation.coordinates.lng
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
                        Annotation(destLabel, coordinate: CLLocationCoordinate2D(
                            latitude: last.toStation.coordinates.lat,
                            longitude: last.toStation.coordinates.lng
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
                        Annotation("", coordinate: CLLocationCoordinate2D(
                            latitude: leg.fromStation.coordinates.lat,
                            longitude: leg.fromStation.coordinates.lng
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
                // Outside the route branch: it marks where they are, which is worth
                // showing whether or not a route is on screen. Orange, so it never reads
                // as part of a route — the green origin dot and the red destination pin
                // are the route's own endpoints, and this is neither.
                //
                // `UserAnnotation`, not an `Annotation` at `vm.userLocation`. An
                // `Annotation`'s coordinate is not animatable: assigning a new one moves
                // the view on the next frame, so the dot teleported from fix to fix — it
                // hopped a car length every second or so instead of travelling.
                //
                // MapKit positions this one itself, through the same puck animator Maps
                // uses: it interpolates between fixes and projects a little past the last
                // one at the pace being kept, so the dot moves continuously while the
                // passenger moves and settles when they stop. Supplying content here keeps
                // our styling and gives up only the stock blue puck's look — the heading
                // cone and accuracy ring were never drawn anyway.
                //
                // Note this is fed by MapKit's own location service, not by
                // `vm.userLocation`. That feed still runs, for the resting camera and the
                // search fields; the dot no longer depends on it.
                //
                // Dropped from the content while the tab is away, which is how MapKit's
                // feed is told to stop — there is no switch for it, and leaving a second
                // location service running behind another tab is the expense
                // `stopTrackingUserLocation` exists to avoid.
                //
                // The `(UserLocation) -> Content` overload, not the plain one: it hands
                // back the same location MapKit is rendering the dot at, speed included —
                // `PassengerPuck` reads that to know when to breathe. A second
                // `CLLocationManager` reading of our own would drift a fix or two from
                // what's actually on screen.
                if isOnScreen {
                    UserAnnotation { userLocation in
                        PassengerPuck(speed: userLocation.location?.speed)
                    }
                }
            }
            .ignoresSafeArea()
            // Long-press on map: first press sets origin, subsequent presses set destination.
            //
            // Attached to the Map itself, *above* the safeAreaInsets. Modifiers applied
            // after `.safeAreaInset` attach to the composed view, so when this sat at the
            // bottom of the chain its hit region covered the search panel and the results
            // panel too — and a `DragGesture(minimumDistance: 0)` spanning those claims
            // the touch the instant a finger lands, which is what stopped the route-detail
            // leg list from scrolling. Here the panels sit on top of the gesture's view
            // and take their own touches first.
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
                searchPanel
                    .padding(Self.panelPadding)
                    // The measurement is published from the card/pill itself, not from
                    // here — see `measuresVisibleTop`. Reading the padded panel's own
                    // frame would fold the suggestion list into it.
                    .onPreferenceChange(VisibleTopKey.self) { visibleTop = $0 }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !vm.routeOptions.isEmpty {
                    RouteResultsPanel(
                        options: vm.routeOptions,
                        onSelect: { vm.selectRoute($0) },
                        onPreview: { vm.previewRoute($0) }
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
            .animation(DesignTokens.Motion.cardEnter, value: vm.routeOptions.isEmpty)
            // Rebuild the cached geometry whenever the route itself changes — identity is
            // the leg list, since RouteLeg.id is a fresh UUID per computed route.
            .onChange(of: vm.routeResult?.legs.map(\.id), initial: true) { _, _ in
                routeGeometry = vm.routeResult.flatMap(RouteGeometry.init)
            }
            // One debounced fit, not one per frame.
            //
            // The strip edges are measured with a GeometryReader, so they
            // deliver a new value on *every frame* of an animated height change — and
            // opening route details animates the panel's height over ~0.8s of spring.
            // Fitting on each of those restarted a 0.5s camera animation ~60 times, so
            // the camera was perpetually re-targeted and never converged. That was the
            // lag. `.task(id:)` cancels the pending fit as soon as a newer height
            // arrives, so fitMap runs once, after the panel settles.
            .task(id: FitTrigger(visibleTop: visibleTop,
                                 visibleBottom: visibleBottom,
                                 isLoading: vm.isLoading)) {
                guard !vm.isLoading, let result = vm.routeResult else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                fitMap(to: result)
            }
            // Live position for as long as the map is on screen — for the resting camera
            // and the search fields. The dot is MapKit's own (see `UserAnnotation` above)
            // and does not come from here.
            .onAppear {
                vm.startTrackingUserLocation()
                isOnScreen = true
                mapProxy = proxy
            }
            // The tab bar makes this fire on every tab switch, which is exactly when both
            // location feeds should stop.
            .onDisappear {
                vm.stopTrackingUserLocation()
                isOnScreen = false
            }
            // Rest the camera on the passenger whenever there is no route to frame — on
            // first load, and again after Reset clears one. Keyed on the strip as well as
            // the fix, so the first centring waits for the panels to be measured instead
            // of landing on the raw screen centre and then jumping.
            .task(id: HomeTrigger(hasUserLocation: vm.userLocation != nil,
                                  visibleTop: visibleTop,
                                  visibleBottom: visibleBottom,
                                  hasRoute: vm.routeResult != nil)) {
                // `calculateRoute()` clears `routeResult` to `nil` the instant a search
                // starts, well before the new one is ready — flipping `hasRoute` false and
                // making this task eligible to fire mid-search. Without the `isLoading`
                // guard, a search that took just over the 80ms below raced this against
                // `fitMap`'s own task below: `recenterHome` would land on the passenger,
                // then `fitMap` would try to animate from there to the route a moment
                // later — two `withAnimation` camera writes close enough together that
                // MapKit dropped the second's animation and snapped instead of gliding.
                // That, not a broken `fitMap`, is what read as "doesn't animate to show
                // the route": which one won was a race with the engine's own timing, so it
                // didn't reproduce on every search.
                guard vm.routeResult == nil, !vm.isLoading else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                recenterHome()
            }
            .task(id: vm.isLoading) {
                if vm.isLoading {
                    try? await Task.sleep(for: DesignTokens.Motion.progressGraceDelay)
                    if vm.isLoading { showSearchProgress = true }
                } else if showSearchProgress {
                    try? await Task.sleep(for: DesignTokens.Motion.progressMinVisible)
                    showSearchProgress = false
                }
            }
            #if DEBUG
            // Launch-argument-gated; see DebugRouteSeed. No-op without `-seedRoute`.
            .task {
                guard DebugRouteSeed.isEnabled else { return }
                let seeded = await DebugRouteSeed.apply(to: vm)
                // Assigned after confirming on the view model, so the fields' onChange
                // reads these as a programmatic echo rather than a user edit.
                if let origin = seeded.origin { originText = origin }
                if let destination = seeded.destination { destinationText = destination }
                await DebugRouteSeed.searchIfRequested(on: vm)
            }
            #endif
        }
    }

    // MARK: - Design constants

    private static let orange = Color(red: 0.91, green: 0.38, blue: 0.16)
    private static let originGreen = Color(red: 0.18, green: 0.48, blue: 0.20)
    private static let cardCream = Color(red: 0.96, green: 0.94, blue: 0.90)

    // MARK: - Search Panel

    private var isSearchCollapsed: Bool {
        vm.isLoading || !vm.routeOptions.isEmpty
    }

    private var searchPanel: some View {
        Group {
            if isSearchCollapsed {
                collapsedSearchPill
                    .transition(.opacity)
            } else {
                expandedSearchCard
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSearchCollapsed)
    }

    // MARK: Collapsed pill (shown while loading / showing results)

    private var collapsedSearchPill: some View {
        HStack(spacing: 10) {
            Button(action: resetAll) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(DesignTokens.Colors.ink, lineWidth: 2))
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Circle()
                    .fill(Self.originGreen)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "origin-dot", in: searchNS, properties: .position)

                Text(originText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                    .matchedGeometryEffect(id: "origin-text", in: searchNS, properties: .position)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary)
                    .frame(width: 8, height: 8)
                    .matchedGeometryEffect(id: "dest-dot", in: searchNS, properties: .position)

                Text(destinationText)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                    .matchedGeometryEffect(id: "dest-text", in: searchNS, properties: .position)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(.white))
            .overlay(Capsule().strokeBorder(DesignTokens.Colors.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)

            Spacer()
        }
        .measuresVisibleTop(outerPadding: Self.panelPadding)
    }

    // MARK: Expanded card (default search state)

    private var expandedSearchCard: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                // Origin field
                HStack(spacing: 14) {
                    Circle()
                        .fill(Self.originGreen)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "origin-dot", in: searchNS, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the origin name — used only for geometry matching
                        Text(originText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "origin-text", in: searchNS, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Start", text: $originText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .origin)
                            .onChange(of: originText) { _, val in vm.updateOriginSuggestions(val) }
                    }
                    if vm.isResolvingOrigin {
                        ProgressView().controlSize(.small)
                    } else if !originText.isEmpty {
                        Button(action: clearOrigin) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                dashedDivider.padding(.horizontal, 18)

                // Destination field
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.orange)
                        .frame(width: 10, height: 10)
                        .matchedGeometryEffect(id: "dest-dot", in: searchNS, properties: .position)
                    ZStack(alignment: .leading) {
                        // Invisible anchor for the destination name — geometry matching only
                        Text(destinationText)
                            .font(.system(.body, weight: .semibold))
                            .opacity(0)
                            .matchedGeometryEffect(id: "dest-text", in: searchNS, properties: .position)
                            .allowsHitTesting(false)
                        TextField("Destination", text: $destinationText)
                            .font(.system(.body, weight: .semibold))
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .destination)
                            .onChange(of: destinationText) { _, val in vm.updateDestSuggestions(val) }
                    }
                    if vm.isResolvingDestination {
                        ProgressView().controlSize(.small)
                    } else if !destinationText.isEmpty {
                        Button(action: clearDestination) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                // Action row
                HStack(spacing: 12) {
                    Button {
                        focusedField = nil
                        Task { await vm.calculateRoute() }
                    } label: {
                        Group {
                            if showSearchProgress {
                                ProgressView().tint(.white)
                            } else {
                                Text("SEARCH ROUTE")
                                    .font(.system(.subheadline, weight: .bold))
                                    .kerning(1.2)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Self.orange))
                    }
                    .disabled(!vm.canCalculate || vm.isLoading)
                    .opacity(!vm.canCalculate ? 0.55 : 1)

                    Button(action: swapOriginDestination) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)

                if let error = vm.errorMessage {
                    Text(error)
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(DesignTokens.Colors.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                }
            }
            .background(Self.cardCream)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .cardShadow(y: 4)
            // Measured here rather than on the enclosing VStack: the suggestion list
            // below is a sibling in that stack, so measuring the stack made the strip's
            // top edge move every time the list opened, closed, or changed row count —
            // and that edge keys the camera tasks, which re-framed the map on every
            // keystroke. The list floats over the map; it does not move the card.
            .measuresVisibleTop(outerPadding: Self.panelPadding)

            // Suggestions — outside the clipped card so they aren't cut off
            if vm.showOriginSuggestions && !vm.originSuggestions.isEmpty {
                SuggestionList(suggestions: Array(vm.originSuggestions.prefix(5))) { suggestion in
                    selectOrigin(suggestion)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if vm.showDestSuggestions && !vm.destSuggestions.isEmpty {
                SuggestionList(suggestions: Array(vm.destSuggestions.prefix(5))) { suggestion in
                    selectDestination(suggestion)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .cardShadow(y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignTokens.Motion.suggestEnter, value: suggestionsVisible)
    }

    private var dashedDivider: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(Color.primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .frame(height: 1)
    }

    private var suggestionsVisible: Bool {
        (vm.showOriginSuggestions && !vm.originSuggestions.isEmpty) ||
        (vm.showDestSuggestions && !vm.destSuggestions.isEmpty)
    }

    // MARK: - Actions

    private func selectOrigin(_ suggestion: LocationSuggestion) {
        switch suggestion {
        case .station(let station):
            vm.confirmOriginStation(station)
            originText = station.name
            focusedField = .destination
        case .address(let completion):
            Task {
                if let name = await vm.confirmOriginAddress(completion) {
                    originText = name
                    focusedField = .destination
                }
            }
        }
    }

    private func selectDestination(_ suggestion: LocationSuggestion) {
        switch suggestion {
        case .station(let station):
            vm.confirmDestinationStation(station)
            destinationText = station.name
            focusedField = nil
        case .address(let completion):
            Task {
                if let name = await vm.confirmDestinationAddress(completion) {
                    destinationText = name
                    focusedField = nil
                }
            }
        }
    }

    private func clearOrigin() {
        originText = ""
        vm.originID = ""
        vm.originCoordinate = nil
        vm.confirmedOriginLabel = nil
        vm.lastOriginQuery = ""
        vm.originDebounce?.cancel()
        vm.originSuggestions = []
        vm.showOriginSuggestions = false
    }

    private func clearDestination() {
        destinationText = ""
        vm.destinationID = ""
        vm.destinationCoordinate = nil
        vm.confirmedDestLabel = nil
        vm.lastDestQuery = ""
        vm.destDebounce?.cancel()
        vm.destSuggestions = []
        vm.showDestSuggestions = false
    }

    private func resetAll() {
        focusedField = nil
        clearOrigin(); clearDestination()
        vm.routeResult = nil
        vm.routeOptions = []
        vm.errorMessage = nil
        // Back to the passenger (or the Manila default), strip-centred. The HomeTrigger
        // task fires too when a route was cleared; calling here as well covers Reset with
        // no route on screen, and the two are idempotent.
        recenterHome()
    }

    private func swapOriginDestination() {
        let tempText  = originText
        let tempID    = vm.originID
        let tempCoord = vm.originCoordinate
        let tempLabel = vm.confirmedOriginLabel

        originText              = destinationText
        vm.originID             = vm.destinationID
        vm.originCoordinate     = vm.destinationCoordinate
        vm.confirmedOriginLabel = vm.confirmedDestLabel

        destinationText          = tempText
        vm.destinationID         = tempID
        vm.destinationCoordinate = tempCoord
        vm.confirmedDestLabel    = tempLabel

        // Normalise virtual IDs after the swap
        if vm.originID == RouteRequest.virtualDestID       { vm.originID = RouteRequest.virtualOriginID }
        if vm.destinationID == RouteRequest.virtualOriginID { vm.destinationID = RouteRequest.virtualDestID }

        vm.originDebounce?.cancel()
        vm.destDebounce?.cancel()
        vm.lastOriginQuery       = ""
        vm.lastDestQuery         = ""
        vm.showOriginSuggestions = false
        vm.showDestSuggestions   = false
        vm.originSuggestions     = []
        vm.destSuggestions       = []
    }

    /// Long-press handler: sets the tapped coordinate as origin if unset, destination otherwise.
    private func handleMapLongPress(at coord: Coordinates) {
        if vm.originID.isEmpty {
            vm.setOriginCoordinate(coord)
            originText = "Pinned Location"
            vm.showOriginSuggestions = false
        } else {
            vm.setDestinationCoordinate(coord)
            destinationText = "Pinned Location"
            vm.showDestSuggestions = false
        }
    }

    // Fits the camera to the bounding box of all leg polylines, shifted northward
    // so the route is fully visible in the map area above the results panel.
    private func fitMap(to result: RouteResult) {
        // The bounding box is precomputed per route — see RouteGeometry, which also
        // explains why leg endpoints are folded into it and not just the drawn polylines.
        guard let geo = geometry(for: result) else { return }
        var center = CLLocationCoordinate2D(
            latitude:  (geo.minLat + geo.maxLat) / 2,
            longitude: (geo.minLng + geo.maxLng) / 2
        )
        // 1.2x padding leaves ~8% margin on every side of the visible strip (between the
        // top and bottom cards) — calibrated against a reference screenshot of the target
        // framing: measuring the route's pins and polyline there against the visible strip
        // put the route at ~88% of the screen's width, which is what 1.2x reproduces.
        var latDelta = max((geo.maxLat - geo.minLat) * 1.2, 0.01)
        let lngDelta = max((geo.maxLng - geo.minLng) * 1.2, 0.01)

        // Shift center and expand span so the route sits in the visible map area
        // between the top search pill and the bottom results panel. Map renders
        // edge-to-edge (ignoresSafeArea), so both the collapsed search pill (top)
        // and the results panel (bottom) sit *on top of* the map without reserving
        // space for it — the strip between them is measured, not assumed.
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
    private var visibleStrip: (top: CGFloat, bottom: CGFloat, visible: CGFloat)? {
        let screenH = UIScreen.main.bounds.height
        let stripBottom = visibleBottom > 0 ? visibleBottom : screenH
        guard screenH > 0, stripBottom > visibleTop else { return nil }
        let top    = visibleTop / screenH
        let bottom = (screenH - stripBottom) / screenH
        return (top, bottom, max(1.0 - top - bottom, 0.05))
    }

    /// Moves a camera latitude so the thing it is centred on lands at the middle of the
    /// visible strip instead of the middle of the (partly hidden) screen.
    ///
    /// The shift is measured against the span MapKit will *render*, which is not the span
    /// it is handed. A camera has one zoom for both axes, so MKCoordinateRegion is only a
    /// request: whichever delta is too small for the viewport's aspect ratio gets grown
    /// until it agrees with the other, and what comes back is the larger of the two.
    ///
    /// A wide route is the case that exposed this. Calamba → Los Baños runs east–west, so
    /// its longitude delta dominates: fitting it across 402pt of width sets a zoom at
    /// which 874pt of height covers ~0.43° of latitude — 2.3x the 0.19° `latDelta` asked
    /// for. Shifting by `latDelta` moved the camera less than half as far as intended and
    /// the route settled ~86pt low. A north–south route hit the same code and looked
    /// correct, which is why it survived this long.
    private func shiftedIntoStrip(_ latitude: CLLocationDegrees,
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
    private func recenterHome() {
        let target = vm.userLocation.map {
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

    /// Animates the camera to `region`.
    ///
    /// Goes through `.camera(...)`, not `.region(...)`, on purpose. `MapCameraPosition`
    /// is case-based under the hood — `.camera`, `.region`, `.rect`, and `.item` are each
    /// backed by their own optional accessor, and `positionedByUser` exists specifically
    /// because the framework tracks whether the *current* value came from the passenger's
    /// own pinch/pan. An interactive gesture reports back a camera pose (centre, distance,
    /// heading, pitch), not a lat/lng rectangle, so after the passenger has touched the
    /// map at all, `mapPosition` is holding a `.camera(...)`-cased value. Writing
    /// `.region(...)` over that asks `withAnimation` to interpolate between two different
    /// underlying representations instead of gliding within one — which is where the
    /// animation was silently failing to play. `MapProxy.camera(framing:)` converts our
    /// computed region into the same representation a gesture would have left behind, so
    /// every write here lands in `.camera(...)`, regardless of what the passenger did to
    /// the map beforehand.
    private func moveCamera(to region: MKCoordinateRegion) {
        let target: MapCameraPosition = mapProxy.map { .camera($0.camera(framing: region)) }
            ?? .region(region)
        withAnimation(DesignTokens.Motion.cameraFit) {
            mapPosition = target
        }
    }

    /// The cached geometry when it belongs to `result`, otherwise a freshly built one.
    ///
    /// The fallback covers exactly one frame: `body` runs before the `.onChange` that
    /// refills the cache, so without it a newly computed route would draw nothing on its
    /// first pass. Steady state is a dictionary lookup and no allocation.
    private func geometry(for result: RouteResult) -> RouteGeometry? {
        if let routeGeometry, routeGeometry.matches(result) { return routeGeometry }
        return RouteGeometry(result)
    }

    // Mode styling lives in extension TransportMode (DesignTokens.swift).
}

// MARK: - Passenger Puck

/// Content for the passenger's `UserAnnotation` — position is entirely MapKit's (see the
/// call site); this supplies only the look, orange rather than the stock puck's blue, and
/// one behaviour: a Maps-style idle breathe while the passenger is standing still, which
/// stops the instant `speed` says otherwise. Moving is already its own motion cue; the
/// breathing exists for the moments there isn't one.
private struct PassengerPuck: View {
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
    /// How long a reading has to hold before the pulse commits to it. A GPS speed sample
    /// hovering near the threshold — waiting at a light, a stalled elevator — shouldn't
    /// flicker the halo on and off; this is long enough to ride that out and short enough
    /// that the pulse starts soon after an actual stop.
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
                // A plain assignment, not `withAnimation`: `isStill` already masks
                // `breathe`'s contribution above, so the halo is already at rest the
                // instant this runs — there is nothing left to animate. This just leaves
                // `breathe` clean for the next `withAnimation` to start from.
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

/// Map-ready coordinates for one `RouteResult`: the drawn polyline per leg, plus the
/// bounding box of every leg's polyline *and* its two endpoints.
///
/// Both used to be derived inline — the polylines in `Map`'s content builder, the box in
/// `fitMap` — so each re-evaluation of `ContentView.body` re-allocated the entire
/// coordinate set. Walk legs are filled in from MKDirections by `WalkRouteRefiner` and run
/// to hundreds of points apiece, and `panelHeight` changes on every frame of the results
/// panel's height animation, so that work ran ~60 times per "see route details" tap.
/// Computed once per route instead.
private struct RouteGeometry {
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

// MARK: - Suggestion List

struct SuggestionList: View {
    let suggestions: [LocationSuggestion]
    let onSelect: (LocationSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Identity must be content-based (LocationSuggestion.id), not positional
            // (\.offset): destSuggestions/originSuggestions can be replaced mid-interaction
            // when the address completer's onUpdate re-merges results, so a tap resolved by
            // screen slot rather than by which suggestion it actually is can fire on stale
            // content — e.g. the row still reads "Ayala" but the array now has a different
            // station at that index, and the wrong one gets confirmed.
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onSelect(suggestion) } label: {
                    row(for: suggestion)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider().padding(.leading, 48)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for suggestion: LocationSuggestion) -> some View {
        switch suggestion {
        case .station(let station):
            HStack(spacing: 12) {
                Image(systemName: mode(of: station)?.icon ?? "figure.walk")
                    .foregroundStyle(mode(of: station)?.color ?? Color(.systemGray))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(DesignTokens.TypeScale.body)
                        .foregroundStyle(.primary)
                    Text(lineLabel(for: station))
                        .font(DesignTokens.TypeScale.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        case .address(let completion):
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .font(DesignTokens.TypeScale.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func mode(of station: Station) -> TransportMode? {
        TransportMode(rawValue: station.type)
    }

    // Commuter-facing line label: hyphenated keys (MRT-3, LRT-1) are real-world
    // line names and pass through; underscored keys (JEEPNEY_QUIAPO) are internal
    // ids — show the mode's display name instead of leaking the raw key.
    private func lineLabel(for station: Station) -> String {
        guard station.line.contains("_") else { return station.line }
        return mode(of: station)?.rawValue.capitalized ?? station.line
    }
}

// MARK: - Preference Keys

/// Top edge of the results panel in global coordinates — where the visible map strip
/// ends. Carries a position, not a height, so nothing has to be assumed about what sits
/// between the panel and the bottom of the screen (a tab bar, the home indicator).
private struct VisibleBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Bottom edge of the search panel in global coordinates — where the visible map strip
/// begins.
private struct VisibleTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Publishes this view's bottom edge — plus the search panel's outer padding — as the
    /// top of the visible map strip.
    ///
    /// Applied to the search card and the collapsed pill, never to a container that also
    /// holds the suggestion list. Only a change in what *permanently* covers the map
    /// should reach `VisibleTopKey`; a transient list that opens over it should not.
    func measuresVisibleTop(outerPadding: CGFloat) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: VisibleTopKey.self,
                                       value: geo.frame(in: .global).maxY + outerPadding)
            }
        )
    }
}

private struct CardsBranchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Route Card Summary

/// Every display string a result card and its detail view need, derived once per
/// `RouteOption` instead of on every body evaluation.
///
/// The card list, the card↔detail morph and the leg list all re-evaluate their
/// bodies on every frame of a spring animation. The derivations below are not
/// free — `payments` intersects a `Set` built from every `rawStep` of every leg,
/// and each timestamp used to allocate a fresh `DateFormatter` — so doing them
/// inline made the morph do O(legs × rawSteps) work per frame, per card.
/// `RouteResultsPanel` builds these once when the option list changes.
struct RouteCardSummary {
    struct LegRow: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String
        let minutesText: String
        let mode: TransportMode
        let isWalk: Bool
    }

    /// One number and its unit — "2" + "hr". Split so the metric row can set the
    /// numeral large and the unit small, which a single formatted string cannot do.
    struct MetricPart: Hashable {
        let value: String
        let unit: String
    }

    /// "2 hours, 32 minutes" — the whole-sentence form, for the compact row and the
    /// detail header where the metric reads as prose.
    let durationText: String
    /// The same duration split for the card's metric row: `[2 hr, 32 min]`.
    let durationParts: [MetricPart]
    /// "2:48" — clock time without the period, so the period can be set smaller.
    let arrivalTime: String
    /// "PM"
    let arrivalPeriod: String
    /// "Arrive at 2:48 PM"
    let arriveText: String
    /// "47" — rendered next to a separate ₱ glyph so the two can scale apart.
    let fareText: String
    /// "1 transfer · 7 mins walking"
    let statsText: String
    /// "2 transfers" / "Direct"
    let transfersText: String
    /// Payment IDs accepted across every ride leg.
    let payments: [String]
    let legRows: [LegRow]

    /// `DateFormatter` init is the expensive part (locale + format parsing); reading
    /// `string(from:)` on a shared instance is thread-safe and ~free.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Clock and period are formatted separately so the metric row can set "2:48"
    /// large and "PM" small — one string cannot carry two sizes.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()

    init(result: RouteResult) {
        durationText = Self.durationLabel(minutes: result.totalTimeMinutes)
        durationParts = Self.durationParts(minutes: result.totalTimeMinutes)
        fareText = "\(Int(result.totalFare))"

        let arrival = result.legs.last?.estimatedArrival
        let arrivalString = arrival.map { Self.timeFormatter.string(from: $0) } ?? ""
        arriveText = arrivalString.isEmpty ? "" : "Arrive at \(arrivalString)"
        arrivalTime = arrival.map { Self.clockFormatter.string(from: $0) } ?? ""
        arrivalPeriod = arrival.map { Self.periodFormatter.string(from: $0) } ?? ""

        let transfers = result.transfers
        transfersText = transfers == 0
            ? "Direct"
            : "\(transfers) transfer\(transfers > 1 ? "s" : "")"

        let walkMins = Int(result.legs
            .filter { $0.mode == .walk && $0.line != "ACCESS_WALK" }
            .reduce(0.0) { $0 + $1.effectiveTravelMinutes }
            .rounded())
        let walkPart = walkMins > 0
            ? " · \(walkMins) min\(walkMins == 1 ? "" : "s") walking"
            : ""
        statsText = transfersText + walkPart

        // Payments common to every ride leg — a payment method only helps if it
        // covers the whole trip.
        let rideLegs = result.legs.filter { $0.mode != .walk }
        if let firstRide = rideLegs.first {
            var common = Set(firstRide.rawSteps.flatMap { $0.edge.acceptedPayments })
            for leg in rideLegs.dropFirst() {
                common.formIntersection(Set(leg.rawSteps.flatMap { $0.edge.acceptedPayments }))
            }
            payments = common.sorted()
        } else {
            payments = []
        }

        legRows = result.legs.map { leg in
            let isWalk = leg.mode == .walk || leg.line == "INTERCHANGE"
            let subtitle: String
            if isWalk {
                subtitle = Self.distanceLabel(leg.distanceKm)
            } else {
                let path = leg.stopCount > 1
                    ? "\(leg.stopCount) stops → \(leg.toStation.shortName)"
                    : "\(leg.fromStation.shortName) → \(leg.toStation.shortName)"
                subtitle = leg.fare > 0 ? "\(path) · ₱\(Int(leg.fare))" : path
            }
            return LegRow(
                id: leg.id,
                title: leg.instruction,
                subtitle: subtitle,
                minutesText: "\(Int(leg.effectiveTravelMinutes.rounded())) min",
                mode: leg.mode,
                isWalk: isWalk
            )
        }
    }

    /// Total trip time as "1 hour, 12 minutes" rather than "72 minutes" — past an hour,
    /// a raw minute count stops being something a passenger can judge at a glance.
    ///
    /// `Duration`'s unit style handles the parts that are easy to get wrong by hand:
    /// pluralisation ("1 hour" vs "2 hours"), dropping a zero remainder ("2 hours",
    /// never "2 hours, 0 minutes"), omitting the hour entirely below 60 minutes, and
    /// translating both the unit names and the separator for the current locale.
    private static func durationLabel(minutes: Double) -> String {
        let wholeMinutes = max(0, Int(minutes.rounded()))
        return Duration.seconds(wholeMinutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// The same duration as `durationLabel`, split into its parts. Built by hand
    /// rather than parsed back out of the formatted string: the hour is dropped
    /// below 60 minutes and the minute is dropped on a whole hour, so "2 hr" and
    /// "45 min" each render as a single part.
    private static func durationParts(minutes: Double) -> [MetricPart] {
        let wholeMinutes = max(0, Int(minutes.rounded()))
        let hours = wholeMinutes / 60
        let remainder = wholeMinutes % 60
        var parts: [MetricPart] = []
        if hours > 0 { parts.append(MetricPart(value: "\(hours)", unit: "hr")) }
        if remainder > 0 || hours == 0 {
            parts.append(MetricPart(value: "\(remainder)", unit: "min"))
        }
        return parts
    }

    /// Metres under a kilometre, rounded to 10 m — so "900 m" never reads "0.9 km".
    private static func distanceLabel(_ km: Double) -> String {
        km < 1
            ? "\(Int((km * 1000).rounded(.toNearestOrAwayFromZero) / 10) * 10) m"
            : String(format: "%.1f km", km)
    }

    static func shortName(forPayment id: String) -> String {
        switch id {
        case "beep_card": return "Beep"
        case "cash":      return "Cash"
        case "gcash":     return "GCash"
        case "maya":      return "Maya"
        case "card":      return "Card"
        default:          return id.capitalized
        }
    }

    static func symbol(forPayment id: String) -> String {
        switch id {
        case "beep_card": return "creditcard.fill"
        case "cash":      return "banknote"
        case "gcash":     return "g.circle.fill"
        case "maya":      return "m.circle.fill"
        case "card":      return "creditcard"
        default:          return "banknote"
        }
    }
}

// MARK: - Route Results Panel

struct RouteResultsPanel: View {
    let options: [RouteOption]
    let onSelect: (RouteOption) -> Void
    let onPreview: (RouteOption) -> Void

    /// ID of the currently expanded card.
    @State private var selectedID: RouteOption.ID?
    /// ID of the option whose full leg breakdown is showing, if any.
    @State private var detailID: RouteOption.ID?
    /// Whether the panel is contracted to just the handle + summary row.
    @State private var isMinimized: Bool = false
    /// Natural heights of the two branches, each measured while the branch is on screen
    /// and retained after it leaves. They drive the container's height so the panel
    /// resizes with the toggle instead of jumping when a branch is removed.
    @State private var cardsBranchHeight: CGFloat = 0
    @State private var detailBranchHeight: CGFloat = 0
    /// Display strings per option, rebuilt only when the option list changes.
    /// Not seeded in `init` — `State(initialValue:)` evaluates its argument on every
    /// init even though only the first one is kept, which is the per-render cost this
    /// cache exists to avoid. The card's `??` fallback covers the first frame.
    @State private var summaries: [RouteOption.ID: RouteCardSummary] = [:]

    /// Shared by the expanded card and the detail view so duration, fare and the
    /// label badge fly between them rather than cross-fading.
    @Namespace private var morphNS

    private static let maxScrollHeight: CGFloat = UIScreen.main.bounds.height * 0.50

    init(options: [RouteOption], onSelect: @escaping (RouteOption) -> Void, onPreview: @escaping (RouteOption) -> Void) {
        self.options = options
        self.onSelect = onSelect
        self.onPreview = onPreview
        // Seed the first card as already-expanded before the first layout pass, not via
        // .onAppear: selecting it a frame later animates the panel's height growth, which
        // races the outer VisibleBottomKey measurement in ContentView (used by fitMap) and
        // leaves it capturing the pre-expansion height — the route then renders partly
        // hidden under the (actually taller) results panel.
        _selectedID = State(initialValue: options.first?.id)
    }

    // Selected option floats to index 0; others follow in their original order.
    private var displayOptions: [RouteOption] {
        guard let id = selectedID,
              let idx = options.firstIndex(where: { $0.id == id }) else { return options }
        var sorted = options
        let selected = sorted.remove(at: idx)
        sorted.insert(selected, at: 0)
        return sorted
    }

    private var selectedOption: RouteOption? {
        options.first { $0.id == selectedID }
    }

    private var detailOption: RouteOption? {
        detailID.flatMap { id in options.first { $0.id == id } }
    }

    private static func buildSummaries(_ options: [RouteOption]) -> [RouteOption.ID: RouteCardSummary] {
        Dictionary(uniqueKeysWithValues: options.map { ($0.id, RouteCardSummary(result: $0.result)) })
    }

    /// Height to hold the branch container at, or `nil` to let it size itself.
    ///
    /// `nil` while minimised — that branch is short and has no measurement of its own —
    /// and `nil` until at least one branch has been measured. When the branch being
    /// shown has no height yet (the first time details open), it holds the *other*
    /// branch's height: the box stays put for the length of the flight, giving the
    /// matched duration, arrival and fare a stationary target, and then animates to the
    /// real height as soon as it is known.
    private var branchHeight: CGFloat? {
        if isMinimized && detailID == nil { return nil }
        let target = detailID == nil ? cardsBranchHeight : detailBranchHeight
        if target > 0 { return target }
        let fallback = detailID == nil ? detailBranchHeight : cardsBranchHeight
        return fallback > 0 ? fallback : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            // ZStack, not VStack: during the swap both branches are in the layout
            // for the length of the transition. Stacked vertically they would add
            // their heights and the panel would balloon to the combined size and
            // snap back — overlaid, the panel interpolates between the two.
            ZStack(alignment: .top) {
                if let option = detailOption, let summary = summaries[option.id] {
                    // Edge to edge: the detail view is the panel in this state, not a
                    // card sitting inside it, so it carries no inset and no chrome of
                    // its own — the panel's fill, corner radius and shadow are its own.
                    RouteDetailCard(
                        option: option,
                        summary: summary,
                        ns: morphNS,
                        onHide: {
                            withAnimation(DesignTokens.Motion.morph) { detailID = nil }
                        }
                    )
                    // Always its natural height. The container decides what the panel
                    // shows; this must stay free to be as tall as its content needs,
                    // or the last leg row gets clipped.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: DetailBranchHeightKey.self, value: geo.size.height)
                        }
                    )
                    .transition(.opacity)
                } else if isMinimized {
                    minimizedRow
                        .transition(.opacity)
                } else {
                    expandedContent
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardsBranchHeightKey.self, value: geo.size.height)
                            }
                        )
                        .transition(.opacity)
                }
            }
            // The container's height, not the branches'. A ZStack is as tall as its
            // tallest child and both branches are present for the length of a
            // transition, so left alone the box sits at max(cards, detail) and then
            // resizes to the survivor the instant the other is removed — unanimated,
            // and only ever in the direction where the outgoing branch was the taller
            // one. That is why closing looked right and opening dropped everything at
            // the end. Driving the height from state instead makes it animate with the
            // same transaction that flips `detailID`, in both directions.
            .frame(height: branchHeight, alignment: .top)
        }
        .background(detailID == nil ? DesignTokens.Colors.cream : DesignTokens.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: -4)
        // Read at panel level, not on the branch: a branch that is not on screen keeps
        // its last reported height, which is what the container animates back to.
        .onPreferenceChange(CardsBranchHeightKey.self) { height in
            if height > 0 { cardsBranchHeight = height }
        }
        .onPreferenceChange(DetailBranchHeightKey.self) { height in
            guard height > 0, height != detailBranchHeight else { return }
            // Animated: on the first open this lands a pass after insertion, so the
            // container grows into the detail's height rather than snapping to it.
            withAnimation(DesignTokens.Motion.morph) { detailBranchHeight = height }
        }
        // Both detail entry points animate explicitly with withAnimation, so no
        // implicit .animation(value: detailID) here — it would apply a second spring.
        // Keyed on the legs, not on the option ids. Option ids now survive walk
        // refinement (see `RouteOption.id`), which is the whole point — but refinement
        // *does* rewrite times, fares and geometry, and keying on ids alone would leave
        // this cache serving the pre-refinement figures for the rest of the search.
        // Refinement only runs on routes that contain a walk leg, and it rebuilds those
        // legs, so a leg-id signature always moves when the numbers do.
        .onChange(of: options.flatMap { $0.result.legs.map(\.id) }, initial: true) { _, _ in
            summaries = Self.buildSummaries(options)
            // Refinement can still *drop* an option whose access walk turned out to be
            // too long to walk, so the selection and the open detail view are re-checked
            // against what survived.
            let ids = options.map(\.id)
            if !ids.contains(where: { $0 == selectedID }) {
                selectedID = ids.first
            }
            if let id = detailID, !ids.contains(id) {
                detailID = nil
            }
        }
    }

    // MARK: Drag handle — tap to minimize / maximize

    private var dragHandle: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                isMinimized.toggle()
            }
        } label: {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 4)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(detailID != nil)
    }

    // MARK: Minimized row — "Search Results" label + expand button

    private var minimizedRow: some View {
        HStack {
            Text("Search Results")
                .font(.subheadline.weight(.heavy))
                .kerning(0.5)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    isMinimized = false
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(8)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Expanded content — header + scrollable card list

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BEST WAY THERE")
                .font(.subheadline.weight(.heavy))
                .kerning(0.8)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(displayOptions) { option in
                        RouteOptionCard(
                            option: option,
                            summary: summaries[option.id] ?? RouteCardSummary(result: option.result),
                            isExpanded: option.id == selectedID,
                            ns: morphNS,
                            onExpand: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    selectedID = option.id
                                }
                                onPreview(option)
                            },
                            onDetails: {
                                withAnimation(DesignTokens.Motion.morph) { detailID = option.id }
                            },
                            onSelect: { onSelect(option) }
                        )
                        .jellyEffect(trigger: option.id == selectedID)
                    }
                }
                .padding(.horizontal, 16)
                // Top padding is not decoration: `jellyEffect` springs the selected card
                // past scale 1.0 on its way back, and a ScrollView clips to its bounds,
                // so without a margin the overshoot — and the expanded card's shadow —
                // is sliced off at the edge.
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            // Self-sizing, capped. Order is load-bearing and reads backwards:
            // `fixedSize` is outermost, so it proposes an unspecified height inwards;
            // the frame passes that through, takes the ScrollView's ideal height — its
            // content's height — and clamps it to the cap. The result is
            // min(content, cap), fixed. Past the cap it simply scrolls.
            //
            // With the two swapped, `.frame(maxHeight:)` ends up outermost and means
            // "flexible up to the cap" rather than "hug, but no more than the cap" — the
            // panel proposes a large height and the list expands to the full cap with
            // empty space below the cards.
            //
            // This replaces a GeometryReader-plus-preference measurement that fed the
            // ScrollView's own `.frame(height:)`. Deriving a container's height from a
            // measurement taken inside it is a one-frame-behind loop: on the first
            // search there was no measurement yet, so the list was laid out at the wrong
            // height and clipped, and it only looked right afterwards because the state
            // survived from the previous search. There is nothing to lag now.
            .frame(maxHeight: Self.maxScrollHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Route Option Card

private struct RouteOptionCard: View {
    let option: RouteOption
    let summary: RouteCardSummary
    let isExpanded: Bool
    /// Panel-level namespace — the expanded card's duration/fare/badge fly into
    /// `RouteDetailCard` rather than cross-fading with it.
    let ns: Namespace.ID
    let onExpand: () -> Void
    let onDetails: () -> Void
    let onSelect: () -> Void

    /// Card-local namespace for the collapsed ↔ expanded morph.
    @Namespace private var localNS

    private var result: RouteResult { option.result }

    // VStack with a persistent header row lets SwiftUI interpolate the card's height
    // smoothly as the conditional sections are added/removed below it.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactBar
            if !isExpanded {
                collapsedSubRow
                    .transition(.opacity)
            }
            if isExpanded {
                expandedSection
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .clipped()
        .background(DesignTokens.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(DesignTokens.Colors.ink.opacity(isExpanded ? 1 : 0.25),
                              lineWidth: isExpanded ? 2 : 1)
        )
        .shadow(color: isExpanded ? .black.opacity(0.10) : .clear, radius: 8, x: 0, y: 3)
    }

    // MARK: Compact bar — only rendered when collapsed.
    // SwiftUI tracks the last-known geometry positions even after this view leaves the
    // hierarchy, so matchedGeometryEffect in expandedSection still animates correctly.

    @ViewBuilder
    private var compactBar: some View {
        if !isExpanded {
            Button(action: onExpand) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        // "2 hours, 32 minutes" is far wider than the "152 min" this
                        // row was sized for, and it shares the line with the badge
                        // and the fare — clamp rather than letting it push them out.
                        Text(summary.durationText)
                            .font(.system(.body, design: .default, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            // Both ends of a matched pair must name the same anchor.
                            // Leading, not centre: the expanded counterpart is a whole
                            // labelled column and far wider than this one line.
                            .matchedGeometryEffect(id: "time", in: localNS,
                                                   properties: .position, anchor: .topLeading)
                        LabelBadge(label: option.label, isCompact: true)
                            .matchedGeometryEffect(id: "badge", in: localNS, properties: .position)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("₱").font(.footnote.bold())
                            Text(summary.fareText).font(.body.bold())
                        }
                        .matchedGeometryEffect(id: "fare", in: localNS,
                                               properties: .position, anchor: .topTrailing)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .transition(.opacity)
        }
    }

    // MARK: Collapsed-only sub-row

    private var collapsedSubRow: some View {
        HStack(spacing: 4) {
            Text(summary.arriveText)
                .font(.caption).foregroundStyle(.secondary)
            if !summary.payments.isEmpty {
                Text("·").font(.caption).foregroundStyle(.secondary)
                Text(summary.payments.map { RouteCardSummary.shortName(forPayment: $0) }
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Expanded-only section

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row 1: label badge | payment chips
            HStack(spacing: 8) {
                LabelBadge(label: option.label)
                    .matchedGeometryEffect(id: "badge", in: localNS, properties: .position)
                    .matchedGeometryEffect(id: morphID("badge"), in: ns, properties: .position)
                Spacer()
                // Two chips is the practical limit before the row wraps into the
                // duration line on the narrowest devices.
                ForEach(summary.payments.prefix(2), id: \.self) { paymentChip($0) }
            }

            metricRow

            dashedDivider

            // Row 3: trip stats | details disclosure
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.caption).foregroundStyle(.secondary)
                Text(summary.statsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Button(action: onDetails) {
                    HStack(spacing: 4) {
                        Text("See route details")
                            .font(.subheadline.weight(.bold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Color.charcoal)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                // Anchored trailing, not centred: both this and its counterpart in
                // the detail header sit at the trailing edge of their row, and the
                // two labels are different widths — matching centres would slide
                // the control sideways on a change the user did not ask for.
                .matchedGeometryEffect(id: morphID("details"), in: ns,
                                       properties: .position, anchor: .trailing)
            }

            // Primary action
            Button(action: onSelect) {
                Text("USE THIS ROUTE")
                    .font(.system(.headline, design: .default, weight: .bold))
                    .kerning(1.0)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(DesignTokens.Colors.action))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
    }

    // MARK: Metric row — total time | arrives | fare
    //
    // Three labelled columns rather than one run-on line. Every column runs through
    // the same builder at the same two text sizes, so weight and colour are the only
    // things that vary: total time is heavy and ink, the other two regular and grey.
    // Anything that varied the *size* per column would make one column sit taller
    // than its neighbours.

    private var metricRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Morph matches sit on the value and heading inside each column, not on the
            // column itself, so each part flies to its own counterpart in the detail.
            MetricColumn(
                heading: "TOTAL TIME",
                parts: summary.durationParts,
                isLeadMetric: true,
                valueMatch: MorphMatch(id: morphID("time"), namespace: ns,
                                       anchor: .bottomLeading)
            )
            .matchedGeometryEffect(id: "time", in: localNS,
                                   properties: .position, anchor: .topLeading)

            columnRule

            // "ARRIVES" flies into the words "Arrive at" in the detail's sentence; the
            // clock value flies to the clock value. Previously the whole column was
            // matched to one Text over there, which left the heading with no counterpart
            // and it just disappeared.
            MetricColumn(
                heading: "ARRIVES",
                parts: [.init(value: summary.arrivalTime, unit: summary.arrivalPeriod)],
                headingMatch: MorphMatch(id: morphID("arriveLabel"), namespace: ns,
                                         anchor: .bottomLeading),
                valueMatch: MorphMatch(id: morphID("arrive"), namespace: ns,
                                       anchor: .bottomLeading)
            )

            Spacer(minLength: 8)

            MetricColumn(
                heading: "FARE",
                parts: [.init(value: "₱\(summary.fareText)", unit: "")],
                alignment: .trailing,
                valueMatch: MorphMatch(id: morphID("fare"), namespace: ns,
                                       anchor: .bottomTrailing)
            )
            .matchedGeometryEffect(id: "fare", in: localNS,
                                   properties: .position, anchor: .topTrailing)
        }
        // Only a backstop for the largest Dynamic Type sizes. At the default size the
        // row fits without it — which matters, because each Text scales independently
        // and a column that shrinks while its neighbours do not looks mis-sized.
        .minimumScaleFactor(0.8)
    }

    /// Hairline between the total-time and arrival columns. A Shape stretches to the
    /// row's height on its own, so it spans heading and value together.
    private var columnRule: some View {
        Rectangle()
            .fill(DesignTokens.Colors.ink.opacity(0.12))
            .frame(width: 1)
    }

    private var dashedDivider: some View {
        // A 1 pt-tall Path rather than Divider(): the dashed rule is part of the
        // card's visual language and Divider has no dash style.
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(DesignTokens.Colors.ink.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
        }
        .frame(height: 1)
    }

    /// matchedGeometryEffect ids are scoped per option so the panel-level namespace
    /// never holds two sources for the same id while several cards are on screen.
    private func morphID(_ element: String) -> String { "\(option.id)-\(element)" }

    @ViewBuilder
    private func paymentChip(_ paymentID: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: RouteCardSummary.symbol(forPayment: paymentID))
                .font(.caption)
            Text(RouteCardSummary.shortName(forPayment: paymentID))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DesignTokens.Colors.ink.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Label Badge

/// The FASTEST / CHEAPEST badge: solid fill, white text.
///
/// One implementation for the card and the detail header. The detail used to render a
/// soft tinted variant, which meant the badge changed appearance mid-flight; sharing the
/// view keeps the morph a pure translation, the same reason `MetricColumn` is shared.
///
/// `.balanced` has no badge — it is the option with nothing to claim.
private struct LabelBadge: View {
    let label: RouteOption.Label
    var isCompact: Bool = false

    var body: some View {
        if let (text, fill) = content {
            Text(text)
                .font(isCompact ? .caption2.weight(.heavy) : .subheadline.weight(.heavy))
                .kerning(0.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, isCompact ? 7 : 12)
                .padding(.vertical, isCompact ? 3 : 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                // Fixed, not scalable. The badge shares its row with payment chips on the
                // card and with the wider "Hide route details" button in the detail, so a
                // minimumScaleFactor let it compress by different amounts on each side —
                // the badge visibly changed size across the morph. The label is two words
                // at most; it does not need to shrink.
                .fixedSize()
        }
    }

    private var content: (String, Color)? {
        switch label {
        case .fastest:  return ("FASTEST", DesignTokens.Colors.fastest)
        case .cheapest: return ("CHEAPEST", DesignTokens.Colors.cheapest)
        case .balanced: return nil
        }
    }
}

// MARK: - Morph Match

/// A matched-geometry pairing, passed into a shared view so the view can attach the
/// effect to the right part of itself rather than to its outer frame.
private struct MorphMatch {
    let id: String
    let namespace: Namespace.ID
    var anchor: UnitPoint = .center
}

private extension View {
    /// Applies a `MorphMatch` when there is one. The branch is fixed per call site — it
    /// never flips at runtime — so this does not churn view identity.
    @ViewBuilder
    func morphMatched(_ match: MorphMatch?) -> some View {
        if let match {
            matchedGeometryEffect(id: match.id, in: match.namespace,
                                  properties: .position, anchor: match.anchor)
        } else {
            self
        }
    }
}

// MARK: - Metric Column

/// One labelled metric — a heading over one or more value/unit pairs.
///
/// Shared by the result card's metric row and the detail header so that the two are
/// the *same* view with the same content and the same text sizes. That is what makes
/// the card ⇄ detail flight clean: `matchedGeometryEffect` interpolates position
/// only, so if the two sides differ in width the wider one has to centre itself on
/// the narrower one — which sends its leading edge off the side of the card on the
/// way in, then cross-fades it out there.
///
/// Sizes are fixed for every column: `.title2` for values, `.caption` for the heading,
/// and `.subheadline` for units unless `usesInlineUnits` raises them. `isLeadMetric`
/// changes only the weight and the colour.
private struct MetricColumn: View {
    let heading: String
    let parts: [RouteCardSummary.MetricPart]
    var isLeadMetric: Bool = false
    var alignment: HorizontalAlignment = .leading
    /// Renders the unit at the value's size rather than `.subheadline`, and opens the
    /// gap before it to a word space.
    ///
    /// For the detail header, which inlines its columns into a sentence — "48 min,
    /// arrive at 10:19 PM". A `.subheadline` unit is two steps below the `.title2` prose
    /// it sits between, so "min" rendered a 20 pt x-height directly beside "arrive at"'s
    /// 27 pt and the line broke into visibly different text heights instead of reading as
    /// one sentence. The card leaves this off: there the columns are stacked under
    /// headings with nothing but whitespace around them, so a smaller unit reads as a
    /// unit rather than as a shrunken word.
    var usesInlineUnits: Bool = false
    /// The detail header drops the headings — the columns are already established by
    /// the card the passenger just tapped, so repeating them there is noise. The value
    /// stays the last child either way, which is what the `.bottom…` morph anchors
    /// align on, so dropping the heading does not disturb the flight.
    var showsHeading: Bool = true
    /// Attached to the heading and the value separately, rather than to the column as a
    /// whole. The detail header has no headings, so a column-level match would give the
    /// heading nowhere to go and it would simply vanish — matching the heading lets it
    /// fly into the prose that replaces it.
    var headingMatch: MorphMatch? = nil
    var valueMatch: MorphMatch? = nil

    var body: some View {
        let weight: Font.Weight = isLeadMetric ? .heavy : .regular
        VStack(alignment: alignment, spacing: 4) {
            if showsHeading {
                Text(heading)
                    .font(.system(.caption, weight: weight))
                    .kerning(0.8)
                    .morphMatched(headingMatch)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(parts, id: \.self) { part in
                    // 5pt inline, not 3: at `.title2` a rendered space is ~5.4pt, and the
                    // pair has to read as two words of one sentence rather than a number
                    // with a suffix bolted on.
                    HStack(alignment: .firstTextBaseline, spacing: usesInlineUnits ? 5 : 3) {
                        Text(part.value)
                            .font(.system(.title2, weight: weight))
                        if !part.unit.isEmpty {
                            Text(part.unit)
                                .font(.system(usesInlineUnits ? .title2 : .subheadline,
                                              weight: weight))
                        }
                    }
                }
            }
            .morphMatched(valueMatch)
        }
        .lineLimit(1)
        .foregroundStyle(isLeadMetric
                         ? AnyShapeStyle(DesignTokens.Colors.ink)
                         : AnyShapeStyle(.secondary))
    }
}

// MARK: - Route Detail Card

/// Full leg-by-leg breakdown, shown in place of the option list when
/// "See route details" is tapped. It reads from the same precomputed
/// `RouteCardSummary` as the card, so opening it allocates nothing.
private struct RouteDetailCard: View {
    let option: RouteOption
    let summary: RouteCardSummary
    let ns: Namespace.ID
    let onHide: () -> Void

    /// Rows visible before the list has to be scrolled.
    private static let visibleLegLimit = 3
    /// Ceiling for the viewport when the first `visibleLegLimit` rows have not been
    /// measured yet, and a hard cap on tall rows — three rows of wrapped titles with
    /// "Show more" expanded must still leave the header and the panel's chrome on screen.
    private static let maxLegsHeight: CGFloat = UIScreen.main.bounds.height * 0.46

    /// Measured height per leg row. Rows size on width alone, so this is not the
    /// one-pass-behind loop the card list used to have — the viewport height derived
    /// from it never feeds back into what it measures.
    @State private var legRowHeights: [RouteCardSummary.LegRow.ID: CGFloat] = [:]
    /// Row currently aligned to the top of the viewport. Drives the snap haptic.
    @State private var topLegID: RouteCardSummary.LegRow.ID?

    /// Combined height of the first `visibleLegLimit` rows, or `nil` until every one of
    /// them has reported. Rows vary in height — titles wrap to two lines, subtitles are
    /// optional, `ExpandableText` adds a "Show more" control — so "three rows" is a sum,
    /// not a constant.
    private var legsViewportHeight: CGFloat? {
        let ids = summary.legRows.prefix(Self.visibleLegLimit).map(\.id)
        guard !ids.isEmpty else { return nil }
        let heights = ids.compactMap { legRowHeights[$0] }
        guard heights.count == ids.count else { return nil }
        return min(heights.reduce(0, +), Self.maxLegsHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(summary.legRows) { row in
                        legRow(row)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(key: LegRowHeightsKey.self,
                                                           value: [row.id: geo.size.height])
                                }
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Makes each row a snap target for `.viewAligned` below, and gives
                // `scrollPosition` the ids it reports.
                .scrollTargetLayout()
            }
            // Snap row-to-row rather than resting mid-row: the list is a sequence of
            // discrete steps, and a half-cut step at the viewport edge reads as clipping
            // rather than as more content.
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $topLegID)
            // A tick on each snap, matching the picker-style selection it now behaves
            // like. `old != nil` suppresses the one that would otherwise fire as the
            // detail opens and the position binding takes its initial value.
            .sensoryFeedback(trigger: topLegID) { old, new in
                old != nil && new != nil && old != new ? .selection : nil
            }
            // Seeded rather than left nil. `scrollPosition` does not necessarily write the
            // binding until the first scroll, and an unseeded binding makes that first
            // snap a nil → row transition — which the guard above discards, silently
            // eating the one haptic the passenger is most likely to be waiting for.
            // Writing the id the list already rests at scrolls nowhere.
            .onAppear { topLegID = summary.legRows.first?.id }
            .onPreferenceChange(LegRowHeightsKey.self) { heights in
                legRowHeights = heights
            }
            // Self-sizing, capped — same recipe and same modifier order as the card
            // list: `fixedSize` outermost proposes an unspecified height, the frame
            // clamps the resulting ideal height to the cap. Replaces a measured
            // `.frame(height:)`, which sized the list from a GeometryReader inside
            // itself and so was always a layout pass behind — that lag is what left
            // the last leg row half-visible and made the list spring back when
            // scrolled, since its frame and its content disagreed.
            //
            // The cap is the first three rows once they have been measured, so a route
            // with more steps than that shows exactly three and scrolls for the rest.
            // Fewer than three and the ideal height wins, so short routes still hug their
            // content and `scrollBounceBehavior(.basedOnSize)` leaves them unscrollable.
            .frame(maxHeight: legsViewportHeight ?? Self.maxLegsHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header — badge + hide control, then the same duration/fare pair as the card

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LabelBadge(label: option.label)
                    .matchedGeometryEffect(id: morphID("badge"), in: ns, properties: .position)
                Spacer(minLength: 8)
                // Text-then-chevron, matching the card's "See route details", so the
                // pair reads as one control changing state rather than two controls
                // swapping places.
                Button(action: onHide) {
                    HStack(spacing: 4) {
                        Text("Hide route details")
                            .font(.subheadline.weight(.bold))
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .matchedGeometryEffect(id: morphID("details"), in: ns,
                                       properties: .position, anchor: .trailing)
            }

            // The same two columns the card shows, built by the same view. No transfer
            // count here: the card's stats row already carries it, and a third element
            // between duration and fare has nothing to fly to or from.
            // Flat, deliberately: duration, arrival and fare are siblings of one HStack.
            //
            // Duration and arrival were previously wrapped in a nested HStack so the
            // comma could sit tight against "min". That nesting is what broke the
            // animation. `matchedGeometryEffect(properties: .position)` offsets a view
            // inside its immediate parent, but the parent's own frame is laid out
            // normally — so a nested container is positioned by the outer HStack as one
            // block, and the two matched children ride along inside it instead of each
            // arriving from its own source. The pair read as a single sliding text.
            //
            // The tight comma comes from `spacing: 0` plus the Spacer before the fare,
            // which needs no nesting to express.
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                MetricColumn(
                    heading: "TOTAL TIME",
                    parts: summary.durationParts,
                    isLeadMetric: true,
                    usesInlineUnits: true,
                    showsHeading: false,
                    valueMatch: MorphMatch(id: morphID("time"), namespace: ns,
                                           anchor: .bottomLeading)
                )

                // The card's "ARRIVES" heading flies into these words, so the label is
                // carried over rather than dropped. Trailing space, not HStack spacing:
                // the row is spaced 0 so the comma stays tight against "min".
                Text(", arrive at ")
                    .font(.system(.title2, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: morphID("arriveLabel"), in: ns,
                                           properties: .position, anchor: .bottomLeading)

                // Rendered by the same view as the card's clock value, so the two ends
                // of this pairing are identical and the flight is a pure translation.
                MetricColumn(
                    heading: "",
                    parts: [.init(value: summary.arrivalTime, unit: summary.arrivalPeriod)],
                    usesInlineUnits: true,
                    showsHeading: false,
                    valueMatch: MorphMatch(id: morphID("arrive"), namespace: ns,
                                           anchor: .bottomLeading)
                )

                // No fare here. Every leg row below carries its own fare, and the total is
                // already the headline figure on the card the passenger just tapped —
                // repeating it above a breakdown that itemises it is the one number on
                // this screen that says nothing new. The card keeps it, so it reappears on
                // "Hide route details".
                //
                // The card's fare still declares morphID("fare"); with no counterpart here
                // it is simply a lone source, and fades with its branch rather than flying.
                Spacer(minLength: 8)
            }
            // Kept as a backstop for large Dynamic Type only. Dropping the fare frees
            // ~44pt, which is what lets the inline `.title2` units fit at the default size
            // even on a two-part duration ("1 hr 12 min") — and this scales each Text
            // independently, so a row that relies on it looks mis-sized rather than small.
            .minimumScaleFactor(0.8)

            Divider()
                .foregroundStyle(Color.gray)
        }
    }

    // MARK: Leg row

    private func legRow(_ row: RouteCardSummary.LegRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            legIcon(row)
            VStack(alignment: .leading, spacing: 2) {
                ExpandableText(text: row.title,
                               font: .subheadline.weight(.bold),
                               collapsedLineLimit: 2)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The row's only flexible child, which is what makes it the full width the
            // row can spare — and pushes the minutes to the trailing edge without a
            // Spacer. It previously shared that job with a `Spacer(minLength: 8)`:
            // `ExpandableText` is greedy too, so two infinitely-flexible siblings sat in
            // one HStack and SwiftUI split the slack between them. The title ended up
            // ~20pt narrower than the row could give it and wrapped a word early —
            // "Walk from Raymundo to / your destination" broke before "your" even though
            // it fits. Dropping the Spacer also reclaims one 12pt HStack gap.
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.minutesText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Fixed, so the row has exactly one flexible child and the arithmetic is
                // decided rather than arbitrated.
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Walk legs get a dashed ring to echo the dashed walk polyline on the map;
    /// ride legs get a solid tint in their mode color.
    @ViewBuilder
    private func legIcon(_ row: RouteCardSummary.LegRow) -> some View {
        ZStack {
            if row.isWalk {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: TransportMode.walk.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(row.mode.color.opacity(0.15))
                Image(systemName: row.mode.icon)
                    .font(.caption)
                    .foregroundStyle(row.mode.color)
            }
        }
        .frame(width: 32, height: 32)
    }

    private func morphID(_ element: String) -> String { "\(option.id)-\(element)" }
}

// MARK: - Expandable Text

/// Text clamped to `collapsedLineLimit` lines, with a chevron that reveals the rest —
/// but only when there is a rest to reveal.
///
/// SwiftUI exposes no "did this Text truncate?" signal, so the check is done by laying
/// the string out twice off-screen at the live width — once clamped, once free — and
/// comparing heights. Both probes stay clamped-independent of `isExpanded`, otherwise
/// expanding would report "not truncated" and remove the control that collapses it.
private struct ExpandableText: View {
    let text: String
    let font: Font
    let collapsedLineLimit: Int

    @State private var isExpanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// A point of slack absorbs sub-pixel rounding between the two layouts.
    private var isTruncated: Bool { fullHeight > clampedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(font)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(truncationProbe)

            if isTruncated {
                Button {
                    withAnimation(DesignTokens.Motion.disclose) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption.weight(.semibold))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(DesignTokens.Colors.action)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var truncationProbe: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(font)
                .lineLimit(collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReader(ClampedTextHeightKey.self))
            Text(text)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReader(FullTextHeightKey.self))
        }
        .hidden()
        .allowsHitTesting(false)
        .onPreferenceChange(ClampedTextHeightKey.self) { clampedHeight = $0 }
        .onPreferenceChange(FullTextHeightKey.self) { fullHeight = $0 }
    }

    private func heightReader<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.height)
        }
    }
}

private struct ClampedTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of each leg row, keyed by row id, so the detail list can cap its viewport at
/// the first three. Merged rather than reduced to a single value — every row reports, and
/// the sum of a known subset is what the cap needs.
private struct LegRowHeightsKey: PreferenceKey {
    static let defaultValue: [RouteCardSummary.LegRow.ID: CGFloat] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

private struct DetailBranchHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Jelly Effect Modifier

/// Applies a spring-bounce to the view's container (background, border, shadow) when `trigger`
/// changes. The initial compression (scale = 1 − intensity) springs back with low damping so it
/// overshoots slightly before settling — producing the "jelly" feel.
///
/// Usage:
///   RouteOptionCard(...).jellyEffect(trigger: isExpanded)
///   someButton.jellyEffect(trigger: isPressed, intensity: 0.06)
struct JellyEffect<T: Equatable>: ViewModifier {
    let trigger: T
    var intensity: CGFloat = 0.04

    @State private var scale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: trigger) { _, _ in
                scale = 1.0 - intensity
                withAnimation(.spring(response: 0.38, dampingFraction: 0.28)) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    func jellyEffect(trigger: some Equatable, intensity: CGFloat = 0.04) -> some View {
        modifier(JellyEffect(trigger: trigger, intensity: intensity))
    }
}

// MARK: - Route Leg Row
// Replaces the old RouteStepRow. Renders one user-facing RouteLeg:
// one boarding → one alighting, with expandable intermediate stops.

struct RouteLegRow: View {
    let leg: RouteLeg
    @State private var stopsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Main leg row ─────────────────────────────────────────────────
            HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
                // Mode indicator — the transition cue: ride legs show their mode
                // icon in the mode color; walk/interchange legs show the gray
                // figure.walk, so "exit train → walk → board next line" reads
                // as an icon change down the list.
                Image(systemName: leg.mode.icon)
                    .font(.caption)
                    .foregroundStyle(leg.mode.color)
                    .frame(width: 26, height: 26)
                    .background(leg.mode.color.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(leg.instruction)
                        .font(DesignTokens.TypeScale.cardTitle)

                    // A walk past what that stop's role justifies (see AccessPolicy) is
                    // still offered — but never silently. The badge makes the trade-off
                    // the passenger is being asked to accept explicit.
                    if leg.isLongAccessWalk {
                        Label("Long walk · \(walkDistanceLabel)", systemImage: "figure.walk.motion")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(DesignTokens.Colors.warning)
                    }

                    HStack(spacing: DesignTokens.Space.s2) {
                        // Time
                        Label("\(Int(leg.effectiveTravelMinutes)) min", systemImage: "clock")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        // Fare (walk legs have zero fare — hide chip)
                        if leg.fare > 0 {
                            Text("•")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                            Label("₱\(String(format: "%.0f", leg.fare))", systemImage: "banknote")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        // Estimated arrival
                        Text("•")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        Text(arrivalString)
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                    }

                    // Intermediate stops disclosure — only shown when there are stops to expand
                    if leg.stopCount > 1 {
                        Button {
                            withAnimation(DesignTokens.Motion.disclose) {
                                stopsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: DesignTokens.Space.s1) {
                                Text(stopsExpanded
                                     ? "Hide stops"
                                     : "\(leg.stopCount) stop\(leg.stopCount > 1 ? "s" : "")")
                                    .font(DesignTokens.TypeScale.meta)
                                    .foregroundStyle(leg.mode.color)
                                Image(systemName: stopsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(leg.mode.color)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)

            // ── Expandable intermediate stop list ────────────────────────────
            if stopsExpanded && leg.stops.count > 2 {
                let intermediate = leg.stops.dropFirst().dropLast()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(intermediate.enumerated()), id: \.offset) { _, station in
                        HStack(spacing: DesignTokens.Space.s3) {
                            // Vertical track line + small dot
                            ZStack {
                                Rectangle()
                                    .fill(leg.mode.color.opacity(0.35))
                                    .frame(width: 2)
                                Circle()
                                    .fill(leg.mode.color.opacity(0.6))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(width: 10)
                            .padding(.leading, 2)

                            Text(station.name)
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, DesignTokens.Space.s1)
                    }
                }
                .padding(.leading, 38) // align under leg text (26 pt icon + 12 pt gap)
                .transition(.opacity.combined(with: .move(edge: .top))) // motion.disclose
            }
        }
    }

    /// Shared instance — building a `DateFormatter` per body evaluation showed up
    /// while scrolling the leg list. Formatting off a shared instance is thread-safe.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var arrivalString: String {
        Self.timeFormatter.string(from: leg.estimatedArrival)
    }

    /// Walk distance in the same units the out-of-range error uses — metres under a
    /// kilometre, so "900 m" never shows up as "0.9 km".
    private var walkDistanceLabel: String {
        leg.distanceKm < 1
            ? "\(Int((leg.distanceKm * 1000).rounded(.toNearestOrAwayFromZero) / 10) * 10) m"
            : String(format: "%.1f km", leg.distanceKm)
    }
}

// MARK: - Preview Helpers

#if DEBUG
private extension Station {
    static func mock(
        id: String, name: String, shortName: String,
        line: String, type: String,
        lat: Double = 14.5763, lng: Double = 121.0194
    ) -> Station {
        Station(
            id: id, name: name, shortName: shortName,
            line: line, type: type,
            coordinates: Coordinates(lat: lat, lng: lng),
            isTerminal: false, isInterchange: false,
            interchangesWith: nil, amenities: [],
            operatingHours: .init(open: "05:30", close: "23:00"),
            accessPoints: nil
        )
    }
}

private extension RouteLeg {
    static func mock(
        from: Station, to: Station,
        mode: TransportMode, line: String,
        direction: String? = nil,
        stops: [Station]? = nil,
        minutes: Double, fare: Double, distanceKm: Double = 3,
        instruction: String,
        arrival: Date = Date().addingTimeInterval(1800)
    ) -> RouteLeg {
        RouteLeg(
            fromStation: from, toStation: to,
            mode: mode, line: line, direction: direction,
            stops: stops ?? [from, to],
            effectiveTravelMinutes: minutes,
            fare: fare, distanceKm: distanceKm,
            polylineCoordinates: [],
            estimatedArrival: arrival,
            instruction: instruction,
            rawSteps: []
        )
    }
}
#endif

// MARK: - Previews

#Preview("Search Suggestions") {
    let stations: [Station] = [
        .mock(id: "MRT3_AYALA",    name: "Ayala Station",          shortName: "Ayala",       line: "MRT-3",          type: "train"),
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",         shortName: "Buendia",     line: "MRT-3",          type: "train"),
        .mock(id: "LRT1_GIL",     name: "Gil Puyat Station",       shortName: "Gil Puyat",   line: "LRT-1",          type: "train"),
        .mock(id: "BUS_AYALA",    name: "Ayala EDSA Bus Stop",     shortName: "Ayala Bus",   line: "EDSA_BUS",       type: "bus"),
        .mock(id: "JEEP_BGC",     name: "Ayala BGC Gate",          shortName: "BGC Ayala",   line: "EJEEPNEY_BGC",   type: "jeepney"),
    ]
    VStack {
        Text("\"Ayala\" results")
            .font(DesignTokens.TypeScale.meta)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        SuggestionList(suggestions: stations.map(LocationSuggestion.station)) { _ in }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .cardShadow(y: 4)
            .padding(.horizontal)
        Spacer()
    }
    .padding(.top)
    .background(Color(.systemGroupedBackground))
}

#Preview("Route Results Panel") {
    let ayala   = Station.mock(id: "MRT3_AYALA",    name: "Ayala Station",    shortName: "Ayala",      line: "MRT-3", type: "train")
    let kalaw   = Station.mock(id: "MRT3_KALAW",    name: "Kalaw Station",    shortName: "Kalaw",      line: "MRT-3", type: "train")
    let central = Station.mock(id: "LRT1_CENTRAL",  name: "Central Station",  shortName: "Central",    line: "LRT-1", type: "train")
    let avenida = Station.mock(id: "LRT1_AVENIDA",  name: "Avenida Station",  shortName: "Avenida",    line: "LRT-1", type: "train")
    let carriedo = Station.mock(id: "LRT1_CARRIEDO", name: "Carriedo Station", shortName: "Carriedo",  line: "LRT-1", type: "train")

    let mrt3Stops: [Station] = [
        ayala,
        .mock(id: "MRT3_BUENDIA",  name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",     name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        kalaw,
    ]
    let lrt1Stops: [Station] = [central, carriedo, avenida]

    let fastestLegs: [RouteLeg] = [
        .mock(from: ayala,   to: kalaw,   mode: .train, line: "MRT-3", direction: "southbound",
              stops: mrt3Stops, minutes: 12, fare: 28, distanceKm: 4.1,
              instruction: "Ride MRT-3 Southbound to Kalaw",
              arrival: Date().addingTimeInterval(720)),
        .mock(from: kalaw,   to: central, mode: .walk,  line: "walk",
              minutes: 5, fare: 0, distanceKm: 0.4,
              instruction: "Walk to LRT-1 Central Station",
              arrival: Date().addingTimeInterval(1020)),
        .mock(from: central, to: avenida, mode: .train, line: "LRT-1",
              stops: lrt1Stops, minutes: 8, fare: 20, distanceKm: 2.9,
              instruction: "Ride LRT-1 Northbound to Avenida",
              arrival: Date().addingTimeInterval(1500)),
    ]
    let cheapestLegs: [RouteLeg] = [
        .mock(from: ayala, to: avenida, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
              minutes: 48, fare: 15, distanceKm: 9.2,
              instruction: "Ride Jeepney to Avenida",
              arrival: Date().addingTimeInterval(2880)),
    ]

    let fastest  = RouteResult(legs: fastestLegs,  totalTimeMinutes: 25, totalFare: 48,  totalDistanceKm: 7.4, transfers: 2, modes: [.train, .train])
    let cheapest = RouteResult(legs: cheapestLegs, totalTimeMinutes: 48, totalFare: 15,  totalDistanceKm: 9.2, transfers: 0, modes: [.jeepney])

    let options: [RouteOption] = [
        RouteOption(result: fastest,  label: .fastest),
        RouteOption(result: cheapest, label: .cheapest),
    ]

    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        RouteResultsPanel(options: options, onSelect: { _ in }, onPreview: { _ in }).padding()
    }
}

#Preview("Route Leg Row – Train") {
    let from = Station.mock(id: "MRT3_AYALA",   name: "Ayala Station",    shortName: "Ayala",    line: "MRT-3", type: "train")
    let to   = Station.mock(id: "MRT3_KALAW",   name: "Kalaw Station",    shortName: "Kalaw",    line: "MRT-3", type: "train")
    let stops: [Station] = [
        from,
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",    name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .train, line: "MRT-3",
                            direction: "southbound", stops: stops,
                            minutes: 12, fare: 28, distanceKm: 4.1,
                            instruction: "Ride MRT-3 Southbound to Kalaw")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Walk") {
    let from = Station.mock(id: "MRT3_KALAW",  name: "Kalaw Station",   shortName: "Kalaw",  line: "MRT-3", type: "train")
    let to   = Station.mock(id: "LRT1_CENTRAL",name: "Central Station", shortName: "Central",line: "LRT-1", type: "train")
    let leg  = RouteLeg.mock(from: from, to: to, mode: .walk, line: "walk",
                             minutes: 5, fare: 0, distanceKm: 0.4,
                             instruction: "Walk to LRT-1 Central Station")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Jeepney") {
    let from = Station.mock(id: "JEEP_QUIAPO", name: "Quiapo Church",  shortName: "Quiapo", line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let to   = Station.mock(id: "JEEP_CUBAO",  name: "Cubao Terminal", shortName: "Cubao",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let stops: [Station] = [
        from,
        .mock(id: "JEEP_STA_MESA", name: "Sta. Mesa",     shortName: "Sta. Mesa",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        .mock(id: "JEEP_ESPANA",   name: "España Blvd.",  shortName: "España",     line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
                            stops: stops, minutes: 22, fare: 14, distanceKm: 6.8,
                            instruction: "Ride Jeepney (Quiapo–Cubao) to Cubao Terminal")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview {
    ContentView()
}
