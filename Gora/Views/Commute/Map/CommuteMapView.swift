//
//  CommuteMapView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

/// The callbacks the map sends to `ContentView`. The coordinator replaces them on each update.
struct CommuteMapEvents {
    let onCameraSettled: (MKMapCamera) -> Void
    let onTap: (CGPoint) -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onSelectRoute: (RouteOption.ID) -> Void
}

/// The Commute tab map: one `MKMapView` that draws the whole scene.
struct CommuteMapView: UIViewRepresentable {
    let scene: CommuteMapScene
    let controller: CommuteMapController
    let drawAnimator: RouteDrawAnimator
    let events: CommuteMapEvents
    let initialRegion: MKCoordinateRegion

    func makeCoordinator() -> CommuteMapCoordinator {
        CommuteMapCoordinator(drawAnimator: drawAnimator, events: events)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        let configuration = MKStandardMapConfiguration()
        // Hides establishment names and icons. Road and place names still show.
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.setRegion(initialRegion, animated: false)
        controller.mapView = mapView
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.events = events
        context.coordinator.apply(scene)
        let allowsGestures = !scene.locksCamera
        if mapView.isScrollEnabled != allowsGestures {
            mapView.isScrollEnabled = allowsGestures
            mapView.isZoomEnabled = allowsGestures
            mapView.isRotateEnabled = allowsGestures
            mapView.isPitchEnabled = allowsGestures
        }
    }
}
