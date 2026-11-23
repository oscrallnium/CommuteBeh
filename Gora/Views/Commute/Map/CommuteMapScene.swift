//
//  CommuteMapScene.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Scene

/// Everything the Commute map shows in one frame. `ContentView` builds a new scene on each
/// pass, and `CommuteMapCoordinator` diffs it against the map by id. See `Commute-Map.md`.
struct CommuteMapScene {

    /// What the system user-location view shows.
    enum UserDot {
        /// MapKit does not track the passenger.
        case off
        case shown
        /// The view stays on the map but draws nothing, because the snapped puck shows instead.
        case covered
    }

    /// Route lines from bottom to top.
    var lines: [RouteLineDescriptor] = []
    var circle: AccuracyCircleDescriptor?
    /// The snapped passenger puck is one annotation here. Its coordinate changes on each glide tick.
    var annotations: [MapAnnotationDescriptor] = []
    var userDot: UserDot = .off
    /// True while Commute Mode draws steps by tap. A change crossfades the lines over `locationStateDuration`.
    var isManualGuidance = false
    /// The selected route and every route on the map during route choice. Nil and empty otherwise.
    /// A change from one route to another starts the draw-on in the coordinator.
    var selectedRouteID: RouteOption.ID?
    var routeIDs: Set<RouteOption.ID> = []
    /// True while Commute Mode follows the passenger. Pan, zoom, rotate, and pitch are off, so only
    /// the follow camera moves the map. Route Overview turns following off and gives them back.
    var locksCamera = false
}

// MARK: - Lines

/// The part of a route, as fractions of its total length, that one overlay covers.
struct RevealSpan: Equatable {
    let start: Double
    let end: Double

    /// The `strokeEnd` of the overlay when the route is drawn to `fraction`.
    func strokeEnd(at fraction: Double) -> CGFloat {
        guard end > start else { return fraction >= start ? 1 : 0 }
        return CGFloat(min(1, max(0, (fraction - start) / (end - start))))
    }
}

/// The stroke of one overlay. Colors resolve against the map's appearance when applied.
struct LineStroke {
    let color: Color
    let style: StrokeStyle
    /// True when a change of opacity or width between two scenes tweens over `Motion.locationStateDuration`.
    var animatesChange = false
}

/// Identifies a coordinate array without comparing every point.
struct CoordinateSignature: Equatable {
    let count: Int
    let firstLat: Double
    let firstLng: Double
    let lastLat: Double
    let lastLng: Double

    init(_ coordinates: [CLLocationCoordinate2D]) {
        count = coordinates.count
        firstLat = coordinates.first?.latitude ?? 0
        firstLng = coordinates.first?.longitude ?? 0
        lastLat = coordinates.last?.latitude ?? 0
        lastLng = coordinates.last?.longitude ?? 0
    }
}

/// One polyline overlay. The coordinator builds the overlay again only when `signature` changes.
/// A `reveal` of nil draws the overlay in full at all times.
struct RouteLineDescriptor {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let stroke: LineStroke
    let reveal: RevealSpan?
    let signature: CoordinateSignature

    init(id: String, coordinates: [CLLocationCoordinate2D], stroke: LineStroke, reveal: RevealSpan? = nil) {
        self.id = id
        self.coordinates = coordinates
        self.stroke = stroke
        self.reveal = reveal
        self.signature = CoordinateSignature(coordinates)
    }
}

/// The GPS accuracy circle.
struct AccuracyCircleDescriptor {
    let center: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
}
