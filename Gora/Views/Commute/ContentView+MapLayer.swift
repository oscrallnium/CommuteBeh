//
//  ContentView+MapLayer.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Map layer
// These members are internal because `ContentView.body` calls `mapLayer()` and they read
// `ContentView`'s stored properties from another file.

extension ContentView {

    /// The full-bleed map. It sits in its own view, so the 30 Hz reads of the puck and the
    /// route-choice tween invalidate the map only. See `Commute-Map.md`.
    func mapLayer() -> some View {
        CommuteMapLayer(host: self)
    }

    /// The callbacks the map sends back to this screen.
    var mapEvents: CommuteMapEvents {
        CommuteMapEvents(
            onCameraSettled: { camera in
                cameraSettled(distance: camera.centerCoordinateDistance)
                recordObservedCamera(camera)
                #if DEBUG
                // The line helps choose `CommuteCameraMode.distance`.
                if isCommuting {
                    print("[CommuteZoom] distance=\(Int(camera.centerCoordinateDistance.rounded())) m mode=\(commuteCameraMode == .threeD ? "3D" : "2D") pitch=\(camera.pitch) following=\(isFollowingPassenger)")
                }
                if !isCommuting, !debugTrainSimulator.isBusy { debugSimAnchor = camera.centerCoordinate }
                #endif
            },
            onTap: { handleRouteTap(at: $0) },
            onLongPress: { handleMapLongPress(at: Coordinates(lat: $0.latitude, lng: $0.longitude)) },
            onSelectRoute: { selectRouteFromAnnotation($0) })
    }

    /// Describes the map for one frame. Call it from a view `body`, so the reads register.
    func commuteMapScene() -> CommuteMapScene {
        var scene = CommuteMapScene()
        if showsRouteChoice {
            let frame = routeChoiceFrame()
            scene.lines = RouteLineBuilder.choiceLines(frame, legColor: routeStore.legColor)
            scene.annotations = RouteAnnotationBuilder.choiceAnnotations(frame)
            scene.selectedRouteID = frame.routes.first(where: \.isSelected)?.id
            scene.routeIDs = Set(frame.routes.map(\.id))
        } else if let result = routeStore.routeResult, let geometry = geometry(for: result) {
            addRoute(result, geometry: geometry, to: &scene)
        }
        addPassenger(to: &scene)
        scene.locksCamera = isCommuting && isFollowingPassenger
        return scene
    }

    /// The route lines, the station connectors, the destination pin, and the transfer dots.
    /// In Commute Mode the line shows only what is left, or every leg with Location off. See `Commute.md`.
    private func addRoute(_ result: RouteResult, geometry: RouteGeometry, to scene: inout CommuteMapScene) {
        let progress: LegProgress
        var firstConnectedLeg = 0
        let current = commuteEngine?.currentLegIndex ?? 0
        let isManual = isCommuting && routeStore.locationAccess == .off
        scene.isManualGuidance = isManual
        if isManual {
            progress = .manual(currentIndex: current)
        } else if isCommuting {
            progress = .commuting(currentIndex: current, passenger: displayedPuckCoordinate)
            firstConnectedLeg = min(current, result.legs.count)
        } else {
            progress = .preview
        }
        let connectors = stationAccessConnectors(legs: result.legs[firstConnectedLeg...])
        scene.lines = RouteLineBuilder.routeLines(
            result, geometry: geometry, progress: progress, legColor: routeStore.legColor) + connectors.lines
        scene.annotations = RouteAnnotationBuilder.routeAnnotations(result, geometry: isCommuting ? nil : geometry) + connectors.tips
        if isManual, let start = RouteAnnotationBuilder.stepStart(result, legIndex: current, geometry: geometry) {
            scene.annotations.append(start)
        }
    }

    /// The passenger dot, the snapped puck, and the GPS accuracy circle. The circle is hidden
    /// in Commute Mode, because it centers on the raw fix while the puck shows the snapped position.
    /// Nothing draws while Location is off.
    private func addPassenger(to scene: inout CommuteMapScene) {
        guard isOnScreen, routeStore.locationAccess != .off else { return }
        let snappedPuck = isCommuting && commuteEngine?.snappedLocation != nil ? displayedPuckCoordinate : nil
        scene.userDot = snappedPuck == nil ? .shown : .covered
        if let snappedPuck {
            scene.annotations.append(MapAnnotationDescriptor(
                id: "snappedPuck", coordinate: snappedPuck, title: nil,
                content: .passengerPuck(speed: routeStore.userSpeed, isHidden: false)))
        }
        if !isCommuting, let userCoord = routeStore.userLocation, let radius = displayedAccuracyRadius {
            scene.circle = AccuracyCircleDescriptor(
                center: CLLocationCoordinate2D(latitude: userCoord.lat, longitude: userCoord.lng),
                radius: radius, fill: Color.tangerine.mapOpacity(0.12),
                stroke: Color.tangerine.mapOpacity(0.30), lineWidth: 1)
        }
    }
}

// MARK: - Map layer view

/// Builds the scene inside its own `body`. Observed reads here invalidate this view only.
struct CommuteMapLayer: View {
    let host: ContentView

    var body: some View {
        CommuteMapView(
            scene: host.commuteMapScene(), controller: host.mapController,
            drawAnimator: host.routeDrawAnimator, events: host.mapEvents,
            initialRegion: ContentView.manilaRegion)
    }
}
