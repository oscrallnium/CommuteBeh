//
//  ContentView+MapContent.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI
import MapKit

// MARK: - Map layer
// These members are internal because `ContentView.body` and the other `ContentView+` files
// call them, and because they read `ContentView`'s stored properties from another file.

extension ContentView {

    /// The full-bleed map with its gestures. `choiceFrame` and `revealedFraction` come from
    /// `body`, because the `MapReader` closure runs outside the observation scope of `body`.
    func mapLayer(choiceFrame: RouteChoiceFrame, revealedFraction: Double) -> some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                mapContent(choiceFrame: choiceFrame, revealedFraction: revealedFraction)
            }
            .ignoresSafeArea()
            // Hides establishment names and icons. Road and place names still show.
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // Long-press on the map: the first press sets origin, later presses set destination.
            // Attach it above the `.safeAreaInset` calls. Below them the hit region covers both
            // panels and stops the route-detail leg list from scrolling.
            .gesture(longPressGesture(proxy: proxy))
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
    }

    private func longPressGesture(proxy: MapProxy) -> some Gesture {
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
    }

    // MARK: Map content

    @MapContentBuilder
    private func mapContent(choiceFrame: RouteChoiceFrame, revealedFraction: Double) -> some MapContent {
        if showsRouteChoice {
            routeChoiceMapContent(choiceFrame, legColor: routeStore.legColor, onSelect: selectRouteFromAnnotation)
        } else if let result = routeStore.routeResult, let geo = geometry(for: result) {
            routeMapContent(result, geo: geo, revealedFraction: revealedFraction)
        }
        accuracyCircle
        passengerContent
    }

    @MapContentBuilder
    private func routeMapContent(
        _ result: RouteResult, geo: RouteGeometry, revealedFraction: Double
    ) -> some MapContent {
        // ── Polylines — one per RouteLeg ─────────────────────────────
        // In Commute Mode the line shows only what's left. See `Commute.md`.
        ForEach(Array(result.legs.enumerated()), id: \.element.id) { index, leg in
            legPolyline(index: index, leg: leg, geo: geo, revealedFraction: revealedFraction)
        }
        // Station connectors draw once per station, not once per leg.
        let firstDrawnLeg = isCommuting ? min(commuteEngine?.currentLegIndex ?? 0, result.legs.count) : 0
        stationAccessConnectors(legs: result.legs[firstDrawnLeg...])
        destinationPin(result)
        transferDots(result)
    }

    @MapContentBuilder
    private func legPolyline(
        index: Int, leg: RouteLeg, geo: RouteGeometry, revealedFraction: Double
    ) -> some MapContent {
        // Precomputed, not mapped here: this closure re-runs on every
        // body pass, and walk legs carry hundreds of MKDirections points.
        let coords = geo.polylines[leg.id] ?? []
        if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index < currentIndex {
            completedLegPolylineContent(leg: leg, coords: coords)
        } else if isCommuting, let currentIndex = commuteEngine?.currentLegIndex, index == currentIndex {
            currentLegPolylineContent(
                leg: leg, coords: coords, passenger: displayedPuckCoordinate,
                color: routeStore.legColor(leg))
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

    // ── Destination pin ──────────────────────────────────────────
    @MapContentBuilder
    private func destinationPin(_ result: RouteResult) -> some MapContent {
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
    }

    // ── Transfer dots — start of every leg whose mode differs from the previous leg ──
    // (user dot is added outside the route branch — it shows with or without a route)
    @MapContentBuilder
    private func transferDots(_ result: RouteResult) -> some MapContent {
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
    @MapContentBuilder
    private var accuracyCircle: some MapContent {
        if isOnScreen, !isCommuting, let userCoord = routeStore.userLocation,
           let radius = displayedAccuracyRadius {
            MapCircle(
                center: CLLocationCoordinate2D(latitude: userCoord.lat, longitude: userCoord.lng),
                radius: radius
            )
            .foregroundStyle(Color.tangerine.mapOpacity(0.12))
            .stroke(Color.tangerine.mapOpacity(0.30), lineWidth: 1)
        }
    }

    // ── The passenger ───────────────────────────────────────────────
    // MapKit's own dot outside commute; a route-snapped `Annotation` during
    // commute. See `Commute.md`.
    @MapContentBuilder
    private var passengerContent: some MapContent {
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
}
