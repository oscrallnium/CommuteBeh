//
//  MapAnnotationDescriptor.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/3/26.
//

import SwiftUI
import MapKit

// MARK: - Content

/// What one annotation shows. Two equal values draw the same pixels, so the coordinator
/// hosts a view again only when the value changes.
enum MapAnnotationContent: Equatable {
    case stopMarker(routeID: RouteOption.ID, kind: RouteChoiceFrame.Marker.Kind, name: String,
                    isSelected: Bool)
    case callout(routeID: RouteOption.ID, text: String, label: String, accessibilityText: String,
                 corner: RouteCalloutCorner, isSelected: Bool, isShown: Bool,
                 schedule: RouteCalloutSchedule?)
    case destinationPin
    case transferDot
    case connectorTip(bearing: Double)
    case passengerPuck(speed: CLLocationSpeed?, isHidden: Bool)
    /// The start of the current step when Location is off.
    case stepStart

    private enum ZOrder {
        static let connectorTip: Float = 0
        static let transferDot: Float = 1
        static let stepStart: Float = 1
        static let stopMarker: Float = 2
        static let destinationPin: Float = 3
        static let callout: Float = 10
        static let selectedCallout: Float = 11
        static let passengerPuck: Float = 20
    }

    /// The point of the hosted view that sits on the annotation coordinate.
    var anchor: UnitPoint {
        switch self {
        case .stopMarker(_, let kind, _, _): kind == .destination ? .bottom : .center
        case .callout(_, _, _, _, let corner, _, _, _): corner.unitPoint
        case .destinationPin: .bottom
        case .transferDot, .connectorTip, .passengerPuck, .stepStart: .center
        }
    }

    var zPriority: Float {
        switch self {
        case .connectorTip: ZOrder.connectorTip
        case .transferDot: ZOrder.transferDot
        case .stepStart: ZOrder.stepStart
        case .stopMarker: ZOrder.stopMarker
        case .destinationPin: ZOrder.destinationPin
        case .callout(_, _, _, _, _, let isSelected, _, _): isSelected ? ZOrder.selectedCallout : ZOrder.callout
        case .passengerPuck: ZOrder.passengerPuck
        }
    }

    /// The route that a tap on the annotation selects. Nil when the annotation takes no taps.
    var tappedRouteID: RouteOption.ID? {
        switch self {
        case .stopMarker(let routeID, _, _, _): routeID
        case .callout(let routeID, _, _, _, _, _, let isShown, _): isShown ? routeID : nil
        case .destinationPin, .transferDot, .connectorTip, .passengerPuck, .stepStart: nil
        }
    }
}

// MARK: - Descriptor

/// One annotation of the scene. The id stays the same while the annotation stays on the map.
struct MapAnnotationDescriptor {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let content: MapAnnotationContent
    /// The route fraction at which the draw-on reveals the annotation. Nil shows it at once.
    var revealAt: Double? = nil
    /// Scale of the hosted content about its anchor. A change moves no view and hosts no new content.
    var zoomScale: Double = 1
}
