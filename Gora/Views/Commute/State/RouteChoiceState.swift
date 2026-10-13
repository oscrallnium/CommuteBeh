//
//  RouteChoiceState.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Route Bounds

/// Bounding box of one or more routes, including leg endpoints.
struct RouteBounds {
    let minLat: CLLocationDegrees
    let maxLat: CLLocationDegrees
    let minLng: CLLocationDegrees
    let maxLng: CLLocationDegrees

    init(_ geometry: RouteGeometry) {
        minLat = geometry.minLat; maxLat = geometry.maxLat
        minLng = geometry.minLng; maxLng = geometry.maxLng
    }

    init?(union geometries: [RouteGeometry]) {
        guard !geometries.isEmpty else { return nil }
        minLat = geometries.map(\.minLat).min() ?? 0
        maxLat = geometries.map(\.maxLat).max() ?? 0
        minLng = geometries.map(\.minLng).min() ?? 0
        maxLng = geometries.map(\.maxLng).max() ?? 0
    }
}

// MARK: - Route Choice Frame

/// Everything the map needs to draw all route options for one `body` pass.
struct RouteChoiceFrame {
    struct Marker: Identifiable {
        enum Kind { case destination, transfer }
        let id: String
        let kind: Kind
        let coordinate: CLLocationCoordinate2D
        let name: String
        /// Only the destination of a route that ends on a station shows its name.
        let title: String
    }

    struct Bubble {
        let coordinate: CLLocationCoordinate2D
        let timeText: String
        let accessibilityText: String
        let isShown: Bool
    }

    struct Route: Identifiable {
        let id: RouteOption.ID
        let legs: [RouteLeg]
        let geometry: RouteGeometry
        let isSelected: Bool
        let opacity: Double
        let width: Double
        /// True while the emphasis tween runs. Flat strokes avoid casing and core redrawing
        /// out of step. See `flatRoutePolyline`.
        let isFlat: Bool
        let markers: [Marker]
        let bubble: Bubble?
    }

    /// Alternates first and the selected route last, so it draws on top.
    let routes: [Route]
    let revealedFraction: Double
    /// Camera-distance scale for walk dots, time bubbles, and the destination pin.
    /// See `RouteChoiceState.zoomScale`.
    let zoomScale: Double
}

// MARK: - Route Choice State

/// Holds the route-choice screen state: which option is selected, whether the sheet shows
/// details, and the per-option map data. See `Commute-State.md`.
@Observable
@MainActor
final class RouteChoiceState {

    private struct Entry {
        let geometry: RouteGeometry
        let markers: [RouteChoiceFrame.Marker]
        let timeText: String
        let accessibilityText: String
    }

    var selectedID: RouteOption.ID?
    /// Where the selected route's bubble sits. Nil hides the bubble.
    private(set) var bubbleCoordinate: CLLocationCoordinate2D?
    var isDetailExpanded = false
    /// Camera distance of the last settled map position, in metres.
    var cameraDistance: CLLocationDistance = RouteChoiceState.zoomReferenceDistance

    /// Option ids in the order the engine returned them.
    private var order: [RouteOption.ID] = []
    private var entries: [RouteOption.ID: Entry] = [:]
    private var shownBubbles: Set<RouteOption.ID> = []
    /// The route that lost selection while the emphasis tween runs. Nil at rest.
    private var outgoingID: RouteOption.ID?
    /// Progress of the selection tween, 0...1. Rests at 1.
    private var emphasis: Double = 1

    private var emphasisTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var tweenToken = 0
    private var placementTask: Task<Void, Never>?
    private var lastAnnotationTap: Date?

    static let emphasisDuration: TimeInterval = 0.3
    static let bubbleStagger: Duration = .milliseconds(60)
    private static let placementDelay: Duration = .milliseconds(120)
    private static let bubbleWidth = 110.0
    private static let bubbleHeight = 44.0
    static let alternateOpacity = 0.26
    static let alternateWidth = 4.0
    static let selectedWidth = RouteLine.coreWidth
    /// Camera distance at or below which route decorations draw at full size.
    static let zoomReferenceDistance: CLLocationDistance = 1500
    /// Seconds after an annotation tap during which a map tap does not change selection.
    private static let annotationTapWindow: TimeInterval = 0.3

    // MARK: Sync

    /// Rebuilds the per-option map data. Call whenever the options or their legs change.
    /// A new set of options hides the bubbles until `revealBubbles()` runs.
    func sync(options: [RouteOption]) {
        let ids = options.map(\.id)
        if ids != order {
            shownBubbles = []
            bubbleCoordinate = nil
            revealTask?.cancel()
        }
        order = ids
        guard !options.isEmpty else {
            entries = [:]
            selectedID = nil
            isDetailExpanded = false
            outgoingID = nil
            emphasisTask?.cancel()
            return
        }

        var geometries: [RouteOption.ID: RouteGeometry] = [:]
        for option in options {
            if let cached = entries[option.id]?.geometry, cached.matches(option.result) {
                geometries[option.id] = cached
            } else if let built = RouteGeometry(option.result) {
                geometries[option.id] = built
            }
        }

        var next: [RouteOption.ID: Entry] = [:]
        for option in options {
            guard let geometry = geometries[option.id] else { continue }
            let summary = RouteCardSummary(result: option.result)
            let timeText = summary.durationParts.map { "\($0.value) \($0.unit)" }.joined(separator: " ")
            next[option.id] = Entry(
                geometry: geometry,
                markers: Self.markers(for: option.result),
                timeText: timeText,
                accessibilityText: "\(Self.labelName(option.label)) route, \(summary.durationText)")
        }
        entries = next
        if selectedID.map({ ids.contains($0) }) != true { selectedID = ids.first }
    }

    // MARK: Selection

    /// Selects `id` and starts the emphasis tween between the old and new route.
    func select(_ id: RouteOption.ID) {
        guard id != selectedID, order.contains(id) else { return }
        outgoingID = selectedID
        selectedID = id
        runEmphasisTween()
    }

    /// Selects `id` from a bubble or marker tap. The map tap that arrives with it is ignored.
    func selectFromAnnotation(_ id: RouteOption.ID) {
        lastAnnotationTap = Date()
        select(id)
    }

    var isAnnotationTapRecent: Bool {
        guard let lastAnnotationTap else { return false }
        return Date().timeIntervalSince(lastAnnotationTap) < Self.annotationTapWindow
    }

    private func runEmphasisTween() {
        tweenToken += 1
        let token = tweenToken
        emphasisTask?.cancel()
        emphasis = 0
        emphasisTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DesignTokens.Motion.headingTickInterval))
                guard let self, self.tweenToken == token else { return }
                let fraction = min(1, Date().timeIntervalSince(startedAt) / Self.emphasisDuration)
                self.emphasis = 1 - (1 - fraction) * (1 - fraction)
                if fraction >= 1 {
                    self.outgoingID = nil
                    return
                }
            }
        }
    }

    // MARK: Bubbles

    /// Springs the bubbles in one at a time, in option order.
    func revealBubbles() {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            for id in self?.order ?? [] {
                guard !Task.isCancelled, let self else { return }
                self.shownBubbles.insert(id)
                try? await Task.sleep(for: Self.bubbleStagger)
            }
        }
    }

    /// Places the selected route's bubble after `placementDelay`, so a burst of calls runs
    /// once. `visible` is the map area in screen points that no panel covers. A route with
    /// no valid spot hides the bubble.
    func scheduleBubblePlacement(
        options: [RouteOption], visible: CGRect,
        project: @escaping (CLLocationCoordinate2D) -> CGPoint?,
        unproject: @escaping (CGPoint) -> CLLocationCoordinate2D?
    ) {
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            try? await Task.sleep(for: Self.placementDelay)
            guard !Task.isCancelled, let self else { return }
            self.placeBubble(options: options, visible: visible, project: project, unproject: unproject)
        }
    }

    private func placeBubble(
        options: [RouteOption], visible: CGRect,
        project: (CLLocationCoordinate2D) -> CGPoint?,
        unproject: (CGPoint) -> CLLocationCoordinate2D?
    ) {
        guard let option = options.first(where: { $0.id == selectedID }),
              let entry = entries[option.id] else { bubbleCoordinate = nil; return }
        let geometry = currentGeometry(of: option, entry: entry)
        let path = option.result.legs.flatMap { geometry.polylines[$0.id] ?? [] }.compactMap(project)
        let scale = max(zoomScale, RouteAnnotationScale.floor)
        let size = CGSize(width: Self.bubbleWidth * scale, height: Self.bubbleHeight * scale)
        let center = RouteBubblePlacement.center(
            path: path, avoid: entry.markers.compactMap { project($0.coordinate) }, visible: visible, size: size)
        let next = center.flatMap(unproject)
        // The bubble glides from its old spot. A first placement appears in place.
        if bubbleCoordinate != nil, next != nil {
            withAnimation(.smooth(duration: 0.35)) { bubbleCoordinate = next }
        } else {
            bubbleCoordinate = next
        }
    }

    // MARK: Map data

    /// The union of every option's bounding box. Nil when no option has geometry.
    var unionBounds: RouteBounds? {
        RouteBounds(union: order.compactMap { entries[$0]?.geometry })
    }

    /// The polyline of each leg per option, for hit testing.
    func hitPaths(for options: [RouteOption]) -> [(id: RouteOption.ID, legs: [[CLLocationCoordinate2D]])] {
        options.compactMap { option in
            guard let geometry = entries[option.id]?.geometry else { return nil }
            return (option.id, option.result.legs.map { geometry.polylines[$0.id] ?? [] })
        }
    }

    /// Builds the draw data for `options`. Reads every observed property here, so the caller
    /// must run this inside `body`, not inside the map content closure.
    func frame(options: [RouteOption], revealedFraction: Double) -> RouteChoiceFrame {
        let isTweening = outgoingID != nil
        let routes = options.compactMap { option -> RouteChoiceFrame.Route? in
            guard let entry = entries[option.id] else { return nil }
            let geometry = currentGeometry(of: option, entry: entry)
            let isSelected = option.id == selectedID
            let (opacity, width) = stroke(for: option.id, isSelected: isSelected)
            let bubble = (isSelected ? bubbleCoordinate : nil).map {
                RouteChoiceFrame.Bubble(
                    coordinate: $0, timeText: entry.timeText,
                    accessibilityText: entry.accessibilityText,
                    isShown: shownBubbles.contains(option.id))
            }
            return RouteChoiceFrame.Route(
                id: option.id, legs: option.result.legs, geometry: geometry,
                isSelected: isSelected, opacity: opacity, width: width, isFlat: isTweening,
                markers: entry.markers,
                bubble: bubble)
        }
        let ordered = routes.filter { !$0.isSelected } + routes.filter(\.isSelected)
        return RouteChoiceFrame(
            routes: ordered, revealedFraction: revealedFraction, zoomScale: routes.isEmpty ? 1 : zoomScale)
    }

    private func currentGeometry(of option: RouteOption, entry: Entry) -> RouteGeometry {
        entry.geometry.matches(option.result) ? entry.geometry : (RouteGeometry(option.result) ?? entry.geometry)
    }

    /// Shrinks walk dots, bubbles, and the destination pin as the camera zooms out. MapKit
    /// draws dashes larger when zoomed out, so the dots need the same ratio. Steps of 0.05
    /// limit overlay redraws.
    private var zoomScale: Double {
        let ratio = Self.zoomReferenceDistance / max(cameraDistance, 1)
        return (min(max(ratio, 0.35), 1) * 20).rounded() / 20
    }

    private func stroke(for id: RouteOption.ID, isSelected: Bool) -> (opacity: Double, width: Double) {
        let rise = Self.alternateOpacity + (1 - Self.alternateOpacity) * emphasis
        let widthRise = Self.alternateWidth + (Self.selectedWidth - Self.alternateWidth) * emphasis
        if isSelected { return (rise, widthRise) }
        if id == outgoingID {
            return (1 - (1 - Self.alternateOpacity) * emphasis,
                    Self.selectedWidth - (Self.selectedWidth - Self.alternateWidth) * emphasis)
        }
        return (Self.alternateOpacity, Self.alternateWidth)
    }

    // MARK: Helpers

    private static func markers(for result: RouteResult) -> [RouteChoiceFrame.Marker] {
        var markers: [RouteChoiceFrame.Marker] = []
        func coordinate(_ station: Station, toward other: Station) -> CLLocationCoordinate2D {
            let point = station.accessPoint(kind: .both, direction: nil, nearestTo: other.coordinates)
            return CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
        }
        if let last = result.legs.last {
            markers.append(.init(
                id: "destination", kind: .destination, coordinate: coordinate(last.toStation, toward: last.fromStation),
                name: last.toStation.shortName,
                title: last.line == "ACCESS_WALK" ? "" : last.toStation.shortName))
        }
        for leg in result.modeChangeLegs {
            markers.append(.init(
                id: "transfer-\(leg.id)", kind: .transfer, coordinate: coordinate(leg.fromStation, toward: leg.toStation),
                name: leg.fromStation.shortName, title: ""))
        }
        return markers
    }

    private static func labelName(_ label: RouteOption.Label) -> String {
        switch label {
        case .fastest: "Fastest"
        case .cheapest: "Cheapest"
        case .balanced: "Balanced"
        }
    }
}
