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
    /// The in-flight search; a new search cancels it.
    @State var searchTask: Task<Void, Never>?
    @State var originText = ""
    @State var destinationText = ""
    @State var mapPosition: MapCameraPosition = .region(Self.manilaRegion)
    /// Captured once the map appears — see `moveCamera`.
    @State var mapProxy: MapProxy?
    @State var showSearchProgress = false
    @FocusState var focusedField: SearchField?
    @Namespace var searchNS
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
    @State var isOnScreen = false
    /// Animated copy of `routeStore.userHorizontalAccuracy` — updated with easeInOut so
    /// the accuracy circle grows and shrinks smoothly rather than jumping between fixes.
    @State var displayedAccuracyRadius: CLLocationAccuracy?
    /// True after the first GPS fix has been applied to the origin field automatically.
    /// Prevents subsequent fixes from overwriting an origin the user has since changed.
    @State var hasAutoSetOrigin = false
    /// The exact text `hasAutoSetOrigin` last wrote — "My Location" or the reverse-geocoded
    /// address. Lets `scenePhase` tell "still what auto-fill wrote" apart from "the
    /// passenger has since edited or replaced it" before deciding to refresh it.
    @State var autoSetOriginText: String?
    /// Watched so returning from the background can re-open two seams a stale position
    /// otherwise gets stuck behind. See `Commute.md`.
    @Environment(\.scenePhase) var scenePhase
    /// The commute sheet stays down while the login cover is up.
    @Environment(UserSession.self) var session
    /// Set on `.background`, cleared on the next real `.active`. See `Commute.md`.
    @State var wasBackgrounded = false
    /// Resolves the best available passenger position: real GPS when fresh, polyline-projected
    /// when fixes stop (tunnel, signal loss). See `CommutePositionResolver`.
    @State var positionResolver = CommutePositionResolver()
    /// Glides the passenger dot between snapped positions at 30 Hz, because `Annotation`
    /// re-places its coordinate instantly rather than animating it. See `PuckGlideInterpolator`.
    @State var puckInterpolator = PuckGlideInterpolator()
    /// Draws a freshly computed route on progressively from origin to destination.
    /// Started by `fitToRouteIfSuccessful` in `ContentView+Camera.swift`, hence internal
    /// rather than private. See `RouteDrawAnimator`.
    @State var routeDrawAnimator = RouteDrawAnimator()
    /// Draws the newly selected route on again after the passenger picks another option.
    /// Started by the `selectedID` observer in `ContentView+Lifecycle.swift`.
    @State var selectionDrawAnimator = RouteDrawAnimator()
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
    @State var isEnteringCommute = false
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
    struct HomeTrigger: Equatable {
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
        let choiceFrame = routeChoiceFrame(
            revealedFraction: revealedFraction,
            selectedRevealedFraction: selectionDrawAnimator.revealedFraction)
        let screen = mapLayer(choiceFrame: choiceFrame, revealedFraction: revealedFraction)
            #if DEBUG
            .overlay(alignment: .topTrailing) { debugSimulateButton }
            #endif
            .safeAreaInset(edge: .top, spacing: 0) { searchPanel }
            .safeAreaInset(edge: .bottom, spacing: 0) { routeChoicePanel }
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
        observed(screen)
    }


    // MARK: - Actions

    /// Runs the search, then frames the result.
    /// Chains the camera fit here rather than observing `routeResult`, so a failed search
    /// leaves the camera where the passenger left it.
    func search() {
        focusedField = nil
        refreshAutoSetOrigin()
        routeDrawAnimator.prepareForNewRoute()
        searchTask?.cancel()
        searchTask = Task {
            await routeStore.calculateRoute()
            guard !Task.isCancelled else { return }
            await fitToRouteIfSuccessful()
        }
    }

    func selectOrigin(_ suggestion: LocationSuggestion) {
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

    func selectDestination(_ suggestion: LocationSuggestion) {
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

    func clearOrigin() {
        originText = ""
        routeStore.originID = ""
        routeStore.originCoordinate = nil
        routeStore.confirmedOriginLabel = nil
        routeStore.lastOriginQuery = ""
        routeStore.originDebounce?.cancel()
        routeStore.originSuggestions = []
        routeStore.showOriginSuggestions = false
    }

    func clearDestination() {
        destinationText = ""
        routeStore.destinationID = ""
        routeStore.destinationCoordinate = nil
        routeStore.confirmedDestLabel = nil
        routeStore.lastDestQuery = ""
        routeStore.destDebounce?.cancel()
        routeStore.destSuggestions = []
        routeStore.showDestSuggestions = false
    }

    func resetAll() {
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
    func evaluateReroute(at location: Coordinates, now: Date) {
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

    func swapOriginDestination() {
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
    func handleMapLongPress(at coord: Coordinates) {
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
