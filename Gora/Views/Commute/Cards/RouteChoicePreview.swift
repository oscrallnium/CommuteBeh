//
//  RouteChoicePreview.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/6/26.
//

#if DEBUG
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Sample data

/// Preview-only routes in Metro Manila. The values are not app data.
private enum Sample {
    typealias Point = (lat: Double, lng: Double)

    struct Stop {
        let name: String
        let line: String
        let type: String
    }

    struct Leg {
        let mode: TransportMode
        let line: String
        let minutes: Double
        let fare: Double
        let instruction: String
        let points: [Point]
    }

    static let accessWalk = "ACCESS_WALK"
    static let lineColorHex = ["MRT3": "#F2C230", "EDSA_CAROUSEL": "#F58017"]
    static let busOffsetLng = 0.0005

    /// EDSA from Cubao to Ayala, north to south. The train runs on this line.
    static let edsa: [Point] = [
        (14.6194, 121.0510), (14.6130, 121.0540), (14.6078, 121.0565), (14.5980, 121.0580),
        (14.5878, 121.0567), (14.5813, 121.0536), (14.5736, 121.0480), (14.5667, 121.0453),
        (14.5600, 121.0400), (14.5540, 121.0343), (14.5490, 121.0278)
    ]

    private static func shifted(_ points: [Point]) -> [Point] {
        points.map { ($0.lat, $0.lng + busOffsetLng) }
    }

    private static let araneta: Point = (14.6230, 121.0540)

    private static let walkToGreenbelt: [Point] = [
        (14.5490, 121.0278), (14.5500, 121.0262), (14.5512, 121.0245), (14.5522, 121.0231), (14.5530, 121.0217)
    ]

    // MARK: Fastest

    private static let fastestStops = [
        Stop(name: "Araneta Center", line: accessWalk, type: "bus"),
        Stop(name: "Cubao", line: "MRT3", type: "train"),
        Stop(name: "Ayala", line: "MRT3", type: "train"),
        Stop(name: "Greenbelt", line: accessWalk, type: "bus")
    ]

    private static let fastestLegs = [
        Leg(mode: .walk, line: accessWalk, minutes: 6, fare: 0, instruction: "Walk to Cubao station",
            points: [araneta, (14.6222, 121.0532), (14.6213, 121.0524), (14.6204, 121.0517), edsa[0]]),
        Leg(mode: .train, line: "MRT3", minutes: 17, fare: 30, instruction: "Ride MRT-3 southbound",
            points: edsa),
        Leg(mode: .walk, line: accessWalk, minutes: 5, fare: 0, instruction: "Walk to Greenbelt",
            points: walkToGreenbelt)
    ]

    // MARK: Balanced

    private static let balancedStops = [
        Stop(name: "Araneta Center", line: accessWalk, type: "bus"),
        Stop(name: "EDSA Cubao", line: "EDSA_CAROUSEL", type: "bus"),
        Stop(name: "Guadalupe", line: "EDSA_CAROUSEL", type: "bus"),
        Stop(name: "Ayala Avenue", line: "JEEPNEY_MAKATI", type: "jeepney"),
        Stop(name: "Greenbelt", line: accessWalk, type: "bus")
    ]

    private static let balancedLegs = [
        Leg(mode: .walk, line: accessWalk, minutes: 6, fare: 0, instruction: "Walk to the EDSA bus stop",
            points: [araneta, (14.6220, 121.0534), (14.6210, 121.0527), (14.6200, 121.0521),
                     (shifted(edsa)[0].lat, shifted(edsa)[0].lng)]),
        Leg(mode: .bus, line: "EDSA_CAROUSEL", minutes: 22, fare: 15, instruction: "Ride the bus southbound",
            points: Array(shifted(edsa)[0...7])),
        Leg(mode: .jeepney, line: "JEEPNEY_MAKATI", minutes: 13, fare: 21, instruction: "Ride the jeepney to Ayala Avenue",
            points: [(14.5667, 121.0458), (14.5640, 121.0420), (14.5610, 121.0380), (14.5580, 121.0340),
                     (14.5555, 121.0300), (14.5535, 121.0245)]),
        Leg(mode: .walk, line: accessWalk, minutes: 5, fare: 0, instruction: "Walk to Greenbelt",
            points: [(14.5535, 121.0245), (14.5533, 121.0232), (14.5530, 121.0217)])
    ]

    // MARK: Cheapest

    private static let cheapestStops = [
        Stop(name: "Araneta Center", line: accessWalk, type: "bus"),
        Stop(name: "Aurora Boulevard", line: "JEEPNEY_NORTH", type: "jeepney"),
        Stop(name: "Ortigas", line: "EDSA_CAROUSEL", type: "bus"),
        Stop(name: "Ayala", line: "EDSA_CAROUSEL", type: "bus"),
        Stop(name: "Greenbelt", line: accessWalk, type: "bus")
    ]

    private static let cheapestLegs = [
        Leg(mode: .walk, line: accessWalk, minutes: 5, fare: 0, instruction: "Walk to the jeepney stop",
            points: [araneta, (14.6224, 121.0536), (14.6216, 121.0532), (14.6208, 121.0526), (14.6200, 121.0520)]),
        Leg(mode: .jeepney, line: "JEEPNEY_NORTH", minutes: 18, fare: 12, instruction: "Ride the jeepney to Ortigas",
            points: [(14.6200, 121.0520), (14.6160, 121.0560), (14.6100, 121.0600), (14.6020, 121.0630),
                     (14.5930, 121.0640), (14.5895, 121.0610), (14.5878, 121.0572)]),
        Leg(mode: .bus, line: "EDSA_CAROUSEL", minutes: 22, fare: 12, instruction: "Ride the bus southbound",
            points: Array(shifted(edsa)[4...10])),
        Leg(mode: .walk, line: accessWalk, minutes: 5, fare: 0, instruction: "Walk to Greenbelt",
            points: [(14.5490, 121.0283)] + Array(walkToGreenbelt.dropFirst()))
    ]

    // MARK: Builders

    /// Fastest, Balanced, Cheapest, in the order the engine returns them.
    static func options() -> [RouteOption] {
        [
            option(.fastest, fastestStops, fastestLegs),
            option(.balanced, balancedStops, balancedLegs),
            option(.cheapest, cheapestStops, cheapestLegs)
        ]
    }

    private static func option(_ label: RouteOption.Label, _ stops: [Stop], _ legs: [Leg]) -> RouteOption {
        let stations = stops.enumerated().map { index, stop in
            let point = index < legs.count ? legs[index].points[0] : legs[legs.count - 1].points.last ?? araneta
            return station(stop, at: point)
        }
        let routeLegs = legs.enumerated().map { index, leg in
            RouteLeg(
                fromStation: stations[index], toStation: stations[index + 1], mode: leg.mode, line: leg.line,
                direction: nil, stops: [stations[index], stations[index + 1]],
                effectiveTravelMinutes: leg.minutes, fare: leg.fare, distanceKm: 3,
                polylineCoordinates: leg.points.map { Coordinates(lat: $0.lat, lng: $0.lng) },
                estimatedArrival: Date().addingTimeInterval(leg.minutes * 60),
                instruction: leg.instruction, rawSteps: [])
        }
        let rides = legs.map(\.mode).filter { $0 != .walk }
        let result = RouteResult(
            legs: routeLegs, totalTimeMinutes: legs.map(\.minutes).reduce(0, +),
            totalFare: legs.map(\.fare).reduce(0, +), totalDistanceKm: Double(legs.count) * 3,
            transfers: max(0, rides.count - 1), modes: rides)
        return RouteOption(result: result, label: label)
    }

    private static func station(_ stop: Stop, at point: Point) -> Station {
        Station(
            id: stop.name, name: stop.name, shortName: stop.name, line: stop.line, type: stop.type,
            coordinates: Coordinates(lat: point.lat, lng: point.lng),
            isTerminal: false, isInterchange: false, interchangesWith: nil, amenities: [],
            operatingHours: .init(open: "05:30", close: "23:00"), accessPoints: nil, sequence: nil, boarding: nil)
    }
}

// MARK: - Layout

private enum Layout {
    /// Share of the screen height that the route fills. The sheet covers the rest.
    static let routeShare = 0.55
    static let routeMargin = 1.2
    static let calloutTop: CGFloat = 80
    static let sheetHeight: CGFloat = 340
    static let sheetBottomInset: CGFloat = 24
    static let settleDelay: Duration = .milliseconds(700)
}

// MARK: - Screen

/// The route choice page: the real map, lines, callouts, and result sheet over the sample routes.
/// The Balanced route is selected.
private struct RouteChoicePreviewScreen: View {
    @State private var routeChoice = RouteChoiceState()
    @State private var controller = CommuteMapController()
    @State private var drawAnimator = RouteDrawAnimator()
    @State private var screenSize = CGSize.zero
    @State private var options: [RouteOption]
    @State private var region: MKCoordinateRegion

    init() {
        let options = Sample.options()
        let state = RouteChoiceState()
        state.sync(options: options)
        state.selectedID = options[1].id
        _routeChoice = State(initialValue: state)
        _options = State(initialValue: options)
        _region = State(initialValue: Self.region(fitting: state.unionBounds))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CommuteMapView(
                scene: scene, controller: controller, drawAnimator: drawAnimator,
                events: events, initialRegion: region)
                .ignoresSafeArea()
            RouteChoiceSheet(
                options: options,
                selectedID: Binding(get: { routeChoice.selectedID }, set: { routeChoice.selectedID = $0 }),
                isDetailExpanded: $routeChoice.isDetailExpanded,
                isCompressed: $routeChoice.isCompressed, canStartCommute: true,
                onUse: { _ in }, legColor: Self.legColor)
                .environment(RouteStore())
                .padding(.horizontal, DesignTokens.Space.sm)
                .padding(.bottom, Layout.sheetBottomInset)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { screenSize = $0 }
        .task { await revealCallouts() }
        .onChange(of: routeChoice.selectedID) { _, _ in placeCallouts() }
    }

    /// Mirrors `RouteStore.legColor` with the live graph line colors.
    private static func legColor(_ leg: RouteLeg) -> Color {
        leg.mode == .walk ? leg.mode.color : Sample.lineColorHex[leg.line].flatMap(Color.init(hex:)) ?? leg.mode.color
    }

    private var scene: CommuteMapScene {
        let frame = routeChoice.frame(options: options)
        var scene = CommuteMapScene()
        scene.lines = RouteLineBuilder.choiceLines(frame, legColor: Self.legColor)
        scene.annotations = RouteAnnotationBuilder.choiceAnnotations(frame)
        scene.selectedRouteID = frame.routes.first(where: \.isSelected)?.id
        scene.routeIDs = Set(frame.routes.map(\.id))
        return scene
    }

    private var events: CommuteMapEvents {
        CommuteMapEvents(
            onCameraSettled: { _ in }, onTap: { selectRoute(at: $0) }, onLongPress: { _ in },
            onSelectRoute: { id in withAnimation(.snappy(duration: 0.25)) { routeChoice.selectFromAnnotation(id) } })
    }

    /// Selects the route nearest to a map tap, as `ContentView.handleRouteTap` does.
    private func selectRoute(at point: CGPoint) {
        guard !routeChoice.isAnnotationTapRecent else { return }
        let projected = routeChoice.hitPaths(for: options).map { route in
            RouteHitTesting.ProjectedRoute(
                id: route.id, legs: route.legs.map { $0.compactMap { controller.point(for: $0) } })
        }
        guard let id = RouteHitTesting.nearestRoute(to: point, in: projected, current: routeChoice.selectedID)
        else { return }
        withAnimation(.snappy(duration: 0.25)) { routeChoice.select(id) }
    }

    /// Places the callouts once the map has laid out, then shows them.
    private func revealCallouts() async {
        try? await Task.sleep(for: Layout.settleDelay)
        if let camera = controller.camera { routeChoice.cameraDistance = camera.centerCoordinateDistance }
        placeCallouts()
        routeChoice.revealBubbles()
    }

    /// Places every route callout beside its line, above the sheet.
    private func placeCallouts() {
        let visibleBottom = screenSize.height - Layout.sheetHeight
        routeChoice.scheduleBubblePlacement(
            options: options,
            visible: CGRect(x: 0, y: Layout.calloutTop, width: screenSize.width,
                            height: visibleBottom - Layout.calloutTop),
            project: { controller.point(for: $0) },
            unproject: { controller.coordinate(at: $0) })
    }

    /// A region that puts every route in the top part of the screen, above the sheet.
    private static func region(fitting bounds: RouteBounds?) -> MKCoordinateRegion {
        guard let bounds else { return ContentView.manilaRegion }
        let latSpan = (bounds.maxLat - bounds.minLat) * Layout.routeMargin
        let lngSpan = (bounds.maxLng - bounds.minLng) * Layout.routeMargin
        let latDelta = latSpan / Layout.routeShare
        let top = bounds.maxLat + (latSpan - (bounds.maxLat - bounds.minLat)) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: top - latDelta / 2, longitude: (bounds.minLng + bounds.maxLng) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngSpan))
    }
}

// MARK: - Preview

struct RouteChoicePreview_Previews: PreviewProvider {
    private static let device = PreviewDevice(rawValue: "iPhone 16 Pro Max")

    static var previews: some View {
        Group {
            RouteChoicePreviewScreen()
                .previewDevice(device)
                .previewDisplayName("Light")
                .preferredColorScheme(.light)
            RouteChoicePreviewScreen()
                .previewDevice(device)
                .previewDisplayName("Dark")
                .preferredColorScheme(.dark)
        }
    }
}
#endif
