//
//  CommuteMapController.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

/// The handle that `ContentView` holds on the Commute map. It writes the camera and converts
/// between screen points and coordinates. See `Commute-Map.md`.
@Observable
@MainActor
final class CommuteMapController {

    @ObservationIgnored weak var mapView: MKMapView?

    /// The annotation id of the snapped passenger puck.
    static let snappedPuckID = "snappedPuck"

    private static let animationOptions: UIView.AnimationOptions = [
        .curveEaseInOut, .allowUserInteraction, .beginFromCurrentState
    ]

    /// True once the map view exists. Conversions return nil before then.
    var isAttached: Bool { mapView != nil }

    // MARK: Camera

    /// The camera the map shows now.
    var camera: MKMapCamera? { mapView?.camera }

    /// Moves the camera to `pose`. A nil `duration` writes it at once.
    func setCamera(_ pose: CommuteCameraPose, duration: TimeInterval?) {
        guard let mapView else { return }
        let camera = MKMapCamera(lookingAtCenter: pose.center, fromDistance: pose.distance,
                                 pitch: pose.pitch, heading: pose.heading)
        write(duration) { mapView.camera = camera }
    }

    /// Frames `region` with a flat camera that faces north. A nil `duration` writes it at once.
    func setRegion(_ region: MKCoordinateRegion, duration: TimeInterval?) {
        guard let mapView else { return }
        let target = flatCamera(framing: region, in: mapView)
        write(duration) { mapView.camera = target }
    }

    /// Measures the flat camera that frames `region`, then puts the map back where it was.
    /// `MKMapView` offers no direct region-to-camera conversion.
    private func flatCamera(framing region: MKCoordinateRegion, in mapView: MKMapView) -> MKMapCamera {
        let original = mapView.camera
        mapView.camera = MKMapCamera(lookingAtCenter: original.centerCoordinate,
                                     fromDistance: original.centerCoordinateDistance,
                                     pitch: 0, heading: 0)
        mapView.setRegion(mapView.regionThatFits(region), animated: false)
        let framed = mapView.camera
        mapView.camera = original
        return MKMapCamera(lookingAtCenter: framed.centerCoordinate,
                           fromDistance: framed.centerCoordinateDistance, pitch: 0, heading: 0)
    }

    /// Assigning `mapView.camera` inside a `UIView` animation glides for `duration`. The
    /// `setCamera` and `setRegion` methods ignore the animation block.
    private func write(_ duration: TimeInterval?, _ change: @escaping () -> Void) {
        guard let duration, duration > 0 else {
            change()
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: Self.animationOptions, animations: change)
    }

    // MARK: Puck

    /// Moves the snapped puck annotation to `coordinate` at once, with no scene rebuild. The
    /// follow tick calls it beside `setCamera`, so the puck and the camera reach the map together.
    func movePuck(to coordinate: CLLocationCoordinate2D) {
        guard let coordinator = mapView?.delegate as? CommuteMapCoordinator,
              let puck = coordinator.annotationsByID[Self.snappedPuckID] else { return }
        puck.coordinate = coordinate
    }

    // MARK: Conversion

    /// The coordinate under `point`, in the map view's own space. Nil when the point has no ground.
    func coordinate(at point: CGPoint) -> CLLocationCoordinate2D? {
        guard let mapView else { return nil }
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// The point of `coordinate`, in the map view's own space.
    func point(for coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let mapView else { return nil }
        return mapView.convert(coordinate, toPointTo: mapView)
    }
}
