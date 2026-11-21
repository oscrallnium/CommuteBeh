//
//  CommuteMapCoordinator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

/// Owns the overlays, annotations, renderers, and gestures of the Commute map. `apply(_:)`
/// diffs a scene against the map by id. See `Commute-Map.md`.
@MainActor
final class CommuteMapCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

    private enum Gesture {
        static let longPressSeconds: TimeInterval = 0.5
    }

    static let annotationReuseID = "hostedAnnotation"

    var events: CommuteMapEvents
    let drawAnimator: RouteDrawAnimator
    private(set) weak var mapView: MKMapView?

    // Overlay state. See `CommuteMapCoordinator+Overlays.swift`.
    var lineOverlays: [String: RouteLineOverlay] = [:]
    var renderers: [ObjectIdentifier: RouteLineRenderer] = [:]
    /// True while the lines change between live and manual guidance. New lines fade in and old lines fade out.
    var isSwitchingGuidance = false
    var lastManualGuidance = false
    var fadingInOverlays: Set<ObjectIdentifier> = []
    var fadingOutOverlays: [RouteLineOverlay] = []
    var circleOverlay: MKCircle?
    var circleStyle: AccuracyCircleDescriptor?
    weak var circleRenderer: MKCircleRenderer?

    // Annotation state. See `CommuteMapCoordinator+Annotations.swift`.
    var annotationsByID: [String: CommuteAnnotation] = [:]
    var userDot: CommuteMapScene.UserDot = .off
    var userDotContent: MapAnnotationContent?
    private var lastSelectedRouteID: RouteOption.ID?

    init(drawAnimator: RouteDrawAnimator, events: CommuteMapEvents) {
        self.drawAnimator = drawAnimator
        self.events = events
        super.init()
        drawAnimator.onFrame = { [weak self] fraction in self?.applyReveal(fraction) }
    }

    // MARK: Setup

    func attach(to mapView: MKMapView) {
        self.mapView = mapView
        mapView.delegate = self
        mapView.register(HostedAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.annotationReuseID)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = Gesture.longPressSeconds
        press.delegate = self
        mapView.addGestureRecognizer(press)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        mapView.addGestureRecognizer(tap)

        mapView.registerForTraitChanges([UITraitUserInterfaceStyle.self],
                                        target: self, action: #selector(userInterfaceStyleChanged))
    }

    /// Brings the map in line with `scene`.
    func apply(_ scene: CommuteMapScene) {
        guard let mapView else { return }
        redrawOnSelectionChange(scene)
        redrawOnGeometryChange(scene)
        isSwitchingGuidance = !lineOverlays.isEmpty && scene.isManualGuidance != lastManualGuidance
        lastManualGuidance = scene.isManualGuidance
        applyUserDot(scene.userDot, in: mapView)
        applyOverlays(scene, in: mapView)
        applyAnnotations(scene.annotations, in: mapView)
    }

    /// Restarts the draw-on when the selection moves between two routes that are both on the map.
    /// It runs before the overlay diff, so the reordered lines never show fully drawn.
    /// The first selection and a new search, where the old route is gone, do not restart it.
    private func redrawOnSelectionChange(_ scene: CommuteMapScene) {
        defer { lastSelectedRouteID = scene.selectedRouteID }
        guard let old = lastSelectedRouteID, let new = scene.selectedRouteID, old != new,
              scene.routeIDs.contains(old) else { return }
        drawAnimator.start()
    }

    /// Restarts a running draw-on when a line with a reveal span is new, or has new points or a
    /// new span, such as a refined walk path. Only a restart keeps the legs drawing in order.
    /// A change after the draw-on ends leaves the route fully drawn.
    private func redrawOnGeometryChange(_ scene: CommuteMapScene) {
        guard drawAnimator.isDrawing, !lineOverlays.isEmpty else { return }
        let changed = scene.lines.contains { line in
            guard line.reveal != nil else { return false }
            guard let current = lineOverlays[line.id] else { return true }
            return current.signature != line.signature || current.reveal != line.reveal
        }
        if changed { drawAnimator.start() }
    }

    func selectRoute(_ id: RouteOption.ID) {
        events.onSelectRoute(id)
    }

    // MARK: Gestures

    /// The first press sets the origin and later presses set the destination.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let mapView else { return }
        let coordinate = mapView.convert(recognizer.location(in: mapView), toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        events.onLongPress(coordinate)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let mapView else { return }
        events.onTap(recognizer.location(in: mapView))
    }

    @objc private func userInterfaceStyleChanged() {
        guard let mapView else { return }
        restyleOverlays(in: mapView)
        refreshUserDotView()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// A touch on an annotation view never reaches the map's own tap and press.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is MKAnnotationView { return false }
            view = current.superview
        }
        return true
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        events.onCameraSettled(mapView.camera)
        #if DEBUG
        logPuckPosition(in: mapView)
        logAnnotationPositions(in: mapView)
        #endif
    }

    #if DEBUG
    /// Prints where MapKit places the user-location view against where its coordinate projects.
    private func logPuckPosition(in mapView: MKMapView) {
        let user = mapView.userLocation
        let projected = mapView.convert(user.coordinate, toPointTo: mapView)
        guard let view = mapView.view(for: user) else {
            print("[PuckDebug] no user view distance=\(Int(mapView.camera.centerCoordinateDistance)) coord=\(user.coordinate.latitude),\(user.coordinate.longitude)")
            return
        }
        let viewCenter = view.superview.map { $0.convert(view.center, to: mapView) } ?? view.center
        print("[PuckDebug] distance=\(Int(mapView.camera.centerCoordinateDistance)) pitch=\(mapView.camera.pitch) coord=\(user.coordinate.latitude),\(user.coordinate.longitude) projected=\(projected) viewCenter=\(viewCenter) bounds=\(view.bounds) centerOffset=\(view.centerOffset) transform=\(view.transform) layerTransform=\(view.layer.transform) superview=\(String(describing: type(of: view.superview)))")
        for (index, subview) in view.subviews.enumerated() {
            let subCenter = subview.superview.map { $0.convert(subview.center, to: mapView) } ?? subview.center
            print("[PuckDebug]   sub\(index) type=\(type(of: subview)) hidden=\(subview.isHidden) frame=\(subview.frame) bounds=\(subview.bounds) centerInMap=\(subCenter) transform=\(subview.transform)")
            for (childIndex, child) in subview.subviews.enumerated() {
                let childCenter = child.superview.map { $0.convert(child.center, to: mapView) } ?? child.center
                print("[PuckDebug]     sub\(index).\(childIndex) type=\(type(of: child)) frame=\(child.frame) centerInMap=\(childCenter)")
            }
        }
    }
    #endif

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        refreshUserDotView()
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let annotation = view.annotation as? CommuteAnnotation else { return }
        mapView.deselectAnnotation(annotation, animated: false)
        if let routeID = annotation.descriptor.content.tappedRouteID { selectRoute(routeID) }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let line = overlay as? RouteLineOverlay {
            return renderer(for: line, in: mapView)
        }
        if let circle = overlay as? MKCircle {
            let renderer = MKCircleRenderer(circle: circle)
            circleRenderer = renderer
            styleCircle(renderer, traits: mapView.traitCollection)
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKUserLocation || annotation is CommuteAnnotation,
              let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.annotationReuseID, for: annotation) as? HostedAnnotationView
        else { return nil }
        if let annotation = annotation as? CommuteAnnotation {
            configure(view, for: annotation)
        } else {
            userDotContent = nil
            configureUserDot(view)
        }
        return view
    }
}
