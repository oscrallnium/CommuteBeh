//
//  ContentView+RouteChoice.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import MapKit

// MARK: - Route choice
// The route-choice phase runs from a finished search until the passenger taps
// "Use This Route". These members are internal because they read `ContentView`'s stored
// properties from another file.

extension ContentView {

    /// True while the map shows every route option for the passenger to choose from.
    var showsRouteChoice: Bool {
        !isCommuting && !routeStore.routeOptions.isEmpty
    }

    /// Draw data for every option. Call from `body`, so the reads of `routeChoice` register
    /// with the view's observation scope.
    func routeChoiceFrame(revealedFraction: Double) -> RouteChoiceFrame {
        routeChoice.frame(
            options: routeStore.routeOptions, revealedFraction: revealedFraction)
    }

    /// Identity of every option, its legs, and what walk refinement changes in them. Refinement
    /// keeps option and leg ids but changes the totals and the polylines, so both belong in the key.
    var routeChoiceKey: [AnyHashable] {
        routeStore.routeOptions.flatMap { option -> [AnyHashable] in
            [option.id, option.result.totalTimeMinutes]
                + option.result.legs.flatMap { [$0.id, $0.polylineCoordinates.count] as [AnyHashable] }
        }
    }

    func syncRouteChoice() {
        routeChoice.sync(options: routeStore.routeOptions)
        placeRouteBubble()
    }

    /// Re-places the selected route's bubble beside its line, inside the map area that no panel covers.
    func placeRouteBubble() {
        guard showsRouteChoice, let proxy = mapProxy else { return }
        let size = screenSize
        let bottom = visibleBottom > 0 ? visibleBottom : size.height
        routeChoice.scheduleBubblePlacement(
            options: routeStore.routeOptions,
            visible: CGRect(x: 0, y: visibleTop, width: size.width, height: max(bottom - visibleTop, 0)),
            project: { proxy.convert($0, to: .local) },
            unproject: { proxy.convert($0, from: .local) })
    }

    /// Stores the settled camera distance, then re-places the bubble for the new view.
    func cameraSettled(distance: CLLocationDistance) {
        routeChoice.cameraDistance = distance
        placeRouteBubble()
    }

    /// Keeps the active route in step with the selected option, so walk refinement and
    /// Commute Mode start from the route the map highlights.
    func previewSelectedRoute() {
        guard let id = routeChoice.selectedID,
              let option = routeStore.routeOptions.first(where: { $0.id == id }) else { return }
        routeStore.previewRoute(option)
    }

    func selectRouteOnMap(_ id: RouteOption.ID) {
        withAnimation(.snappy(duration: 0.25)) { routeChoice.select(id) }
    }

    func selectRouteFromAnnotation(_ id: RouteOption.ID) {
        withAnimation(.snappy(duration: 0.25)) { routeChoice.selectFromAnnotation(id) }
    }

    /// Selects the route nearest to a map tap. A tap on a bubble or marker never reaches
    /// here, and a tap in Commute Mode is ignored.
    func handleRouteTap(at point: CGPoint, proxy: MapProxy) {
        guard showsRouteChoice, !routeChoice.isAnnotationTapRecent else { return }
        let projected = routeChoice.hitPaths(for: routeStore.routeOptions).map { route in
            RouteHitTesting.ProjectedRoute(
                id: route.id,
                legs: route.legs.map { $0.compactMap { proxy.convert($0, to: .local) } })
        }
        guard let id = RouteHitTesting.nearestRoute(to: point, in: projected, current: routeChoice.selectedID)
        else { return }
        selectRouteOnMap(id)
    }

    /// Refits the camera to every route after the sheet changes height.
    func refitForDetailToggle() async {
        guard showsRouteChoice else { return }
        await waitForPanelsToSettle()
        guard showsRouteChoice, let bounds = routeChoice.unionBounds else { return }
        fitMap(bounds: bounds, animation: .smooth(duration: DesignTokens.Motion.cameraFitDuration))
    }
}
