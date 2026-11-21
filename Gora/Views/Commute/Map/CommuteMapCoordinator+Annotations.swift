//
//  CommuteMapCoordinator+Annotations.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Annotation diff

extension CommuteMapCoordinator {

    func applyAnnotations(_ descriptors: [MapAnnotationDescriptor], in mapView: MKMapView) {
        var next: [String: CommuteAnnotation] = [:]
        var added: [CommuteAnnotation] = []
        for descriptor in descriptors {
            if let existing = annotationsByID[descriptor.id] {
                if let view = mapView.view(for: existing) as? HostedAnnotationView {
                    if existing.update(descriptor) {
                        configure(view, for: existing)
                    } else {
                        view.setZoomScale(descriptor.zoomScale, animated: true)
                    }
                } else {
                    _ = existing.update(descriptor)
                }
                next[descriptor.id] = existing
            } else {
                let annotation = CommuteAnnotation(descriptor)
                added.append(annotation)
                next[descriptor.id] = annotation
            }
        }
        let removed = annotationsByID.filter { next[$0.key] == nil }.map(\.value)
        annotationsByID = next
        if !removed.isEmpty { mapView.removeAnnotations(removed) }
        if !added.isEmpty { mapView.addAnnotations(added) }
    }

    /// Shows the annotation's content in `view` and sets its layer and touch behavior.
    func configure(_ view: HostedAnnotationView, for annotation: CommuteAnnotation) {
        let content = annotation.descriptor.content
        view.setZoomScale(annotation.descriptor.zoomScale, animated: false)
        view.show(AnnotationContentView(content: content) { [weak self] in self?.selectRoute($0) },
                  anchor: content.anchor, title: annotation.title)
        #if DEBUG
        if let mapView {
            logConfigure(id: annotation.descriptor.id, content: content,
                         coordinate: annotation.coordinate, view: view, in: mapView)
        }
        #endif
        view.zPriority = MKAnnotationViewZPriority(rawValue: content.zPriority)
        view.setRevealed(isRevealed(annotation.descriptor, at: drawAnimator.fraction), animated: false)
        view.isUserInteractionEnabled = content.tappedRouteID != nil && view.isRevealed
    }

    private func isRevealed(_ descriptor: MapAnnotationDescriptor, at fraction: Double) -> Bool {
        descriptor.revealAt.map { fraction >= $0 } ?? true
    }

    /// Reveals each annotation when the draw-on reaches it. A dot pops in once, at the crossing,
    /// and hides at once when the draw restarts. A hidden dot takes no taps.
    func revealAnnotations(at fraction: Double) {
        guard let mapView else { return }
        for annotation in annotationsByID.values where annotation.descriptor.revealAt != nil {
            guard let view = mapView.view(for: annotation) as? HostedAnnotationView else { continue }
            let revealed = isRevealed(annotation.descriptor, at: fraction)
            guard revealed != view.isRevealed else { continue }
            view.setRevealed(revealed, animated: true)
            view.isUserInteractionEnabled = annotation.descriptor.content.tappedRouteID != nil && revealed
        }
    }

    // MARK: User dot

    /// Turns MapKit's location feed on or off, and hides the dot while the snapped puck shows.
    func applyUserDot(_ dot: CommuteMapScene.UserDot, in mapView: MKMapView) {
        userDot = dot
        mapView.showsUserLocation = dot != .off
        refreshUserDotView()
    }

    /// Shows the puck in the system user-location view when its speed or visibility changed.
    func refreshUserDotView() {
        guard let mapView, let view = mapView.view(for: mapView.userLocation) as? HostedAnnotationView
        else { return }
        configureUserDot(view)
    }

    func configureUserDot(_ view: HostedAnnotationView) {
        guard let mapView else { return }
        let content = MapAnnotationContent.passengerPuck(
            speed: mapView.userLocation.location?.speed, isHidden: userDot == .covered)
        view.isUserInteractionEnabled = false
        view.zPriority = MKAnnotationViewZPriority(rawValue: content.zPriority)
        guard content != userDotContent else { return }
        userDotContent = content
        view.show(AnnotationContentView(content: content) { _ in }, anchor: content.anchor, title: nil)
        #if DEBUG
        logConfigure(id: AnnotationLog.userDotID, content: content,
                     coordinate: mapView.userLocation.coordinate, view: view, in: mapView)
        #endif
    }
}

#if DEBUG
// MARK: - Position log

private enum AnnotationLog {
    static let tag = "[Annotation]"
    static let pointFormat = "%.1f"
    static let coordinateFormat = "%.6f"
    static let missingView = "view=nil"
    static let userDotID = "userDot"
    static let sizeTolerance: CGFloat = 0.5
}

extension CommuteMapCoordinator {

    /// Prints each annotation's projected point against the point where its view anchor is drawn.
    func logAnnotationPositions(in mapView: MKMapView) {
        let camera = mapView.camera
        let center = CLLocation(latitude: camera.centerCoordinate.latitude,
                                longitude: camera.centerCoordinate.longitude)
        let sorted = annotationsByID.values
            .map { (annotation: $0, distance: Self.groundDistance(from: center, to: $0.coordinate)) }
            .sorted { $0.distance < $1.distance }
        print("\(AnnotationLog.tag) camera pitch=\(Self.pt(camera.pitch)) heading=\(Self.pt(camera.heading)) "
              + "distance=\(Self.pt(camera.centerCoordinateDistance)) "
              + "center=\(Self.coord(camera.centerCoordinate)) count=\(sorted.count)")
        for entry in sorted {
            print(annotationLine(entry.annotation, fromCenter: entry.distance, in: mapView))
        }
    }

    private func annotationLine(_ annotation: CommuteAnnotation, fromCenter: Double,
                                in mapView: MKMapView) -> String {
        let content = annotation.descriptor.content
        let name = String(describing: content).split(separator: "(").first.map(String.init) ?? ""
        let expected = mapView.convert(annotation.coordinate, toPointTo: mapView)
        var line = "\(AnnotationLog.tag) id=\(annotation.descriptor.id) \(name) "
            + "coord=\(Self.coord(annotation.coordinate)) fromCenter=\(Self.pt(fromCenter)) "
            + "expected=\(Self.point(expected))"
        guard let view = mapView.view(for: annotation) as? HostedAnnotationView else {
            return line + " \(AnnotationLog.missingView)"
        }
        let anchor = content.anchor
        let actual = view.convert(CGPoint(x: anchor.x * view.bounds.width,
                                          y: anchor.y * view.bounds.height), to: mapView)
        let ground = Self.groundDistance(
            from: CLLocation(latitude: annotation.coordinate.latitude,
                             longitude: annotation.coordinate.longitude),
            to: mapView.convert(actual, toCoordinateFrom: mapView))
        let delta = hypot(actual.x - expected.x, actual.y - expected.y)
        line += " actual=\(Self.point(actual)) delta=\(Self.pt(delta)) deltaGround=\(Self.pt(ground))"
        line += " centerOffset=\(Self.point(view.centerOffset))"
        line += " bounds=\(Self.size(view.bounds.size))"
        line += " transform=\(view.transform) layer=\(Self.layerSummary(view.layer.transform))"
        return line + sizeFields(of: view)
    }

    private func sizeFields(of view: HostedAnnotationView) -> String {
        let measured = view.debugMeasuredSize
        guard let fits = view.debugFittingSize, let frame = view.debugContentFrame else { return "" }
        let mismatch = abs(measured.width - fits.width) > AnnotationLog.sizeTolerance
            || abs(measured.height - fits.height) > AnnotationLog.sizeTolerance
        return " measured=\(Self.size(measured)) nowFits=\(Self.size(fits))"
            + " contentFrame=(\(Self.pt(frame.minX)),\(Self.pt(frame.minY)),"
            + "\(Self.pt(frame.width)),\(Self.pt(frame.height))) sizeMismatch=\(mismatch ? "yes" : "no")"
    }

    /// Prints the view state right after `show`: window, on-screen test and measured size.
    func logConfigure(id: String, content: MapAnnotationContent, coordinate: CLLocationCoordinate2D,
                      view: HostedAnnotationView, in mapView: MKMapView) {
        let name = String(describing: content).split(separator: "(").first.map(String.init) ?? ""
        let expected = mapView.convert(coordinate, toPointTo: mapView)
        print("\(AnnotationLog.tag) configure id=\(id) \(name) "
              + "window=\(view.window == nil ? "no" : "yes") "
              + "onScreen=\(mapView.bounds.contains(expected) ? "yes" : "no") "
              + "measured=\(Self.size(view.debugMeasuredSize)) "
              + "centerOffset=\(Self.point(view.centerOffset)) expected=\(Self.point(expected))")
    }

    private static func groundDistance(from origin: CLLocation, to coordinate: CLLocationCoordinate2D) -> Double {
        origin.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private static func pt(_ value: Double) -> String { String(format: AnnotationLog.pointFormat, value) }

    private static func size(_ value: CGSize) -> String { "\(pt(value.width))x\(pt(value.height))" }

    private static func point(_ value: CGPoint) -> String { "(\(pt(value.x)),\(pt(value.y)))" }

    private static func coord(_ value: CLLocationCoordinate2D) -> String {
        String(format: "\(AnnotationLog.coordinateFormat),\(AnnotationLog.coordinateFormat)",
               value.latitude, value.longitude)
    }

    private static func layerSummary(_ t: CATransform3D) -> String {
        "m11=\(pt(t.m11)) m22=\(pt(t.m22)) m41=\(pt(t.m41)) m42=\(pt(t.m42)) m34=\(String(format: "%.5f", t.m34))"
    }
}
#endif
