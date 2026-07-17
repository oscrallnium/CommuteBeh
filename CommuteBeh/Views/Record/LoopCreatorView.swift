//
//  LoopCreatorView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Phase

enum CreationPhase {
    case recording, reviewing, definingStops, fillingMetadata, output
}

// MARK: - MKPolyline coordinates helper

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// MARK: - RDP Simplifier

struct RDPSimplifier {
    static func simplify(_ points: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var maxDist = 0.0
        var index = 0
        let end = points.count - 1
        for i in 1..<end {
            let d = perpendicularDistance(point: points[i], lineStart: points[0], lineEnd: points[end])
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > epsilon {
            let left  = simplify(Array(points[0...index]), epsilon: epsilon)
            let right = simplify(Array(points[index...end]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [points[0], points[end]]
    }

    private static func perpendicularDistance(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> Double {
        let dx = lineEnd.longitude - lineStart.longitude
        let dy = lineEnd.latitude  - lineStart.latitude
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = point.longitude - lineStart.longitude
            let ey = point.latitude  - lineStart.latitude
            return sqrt(ex * ex + ey * ey)
        }
        let t = max(0, min(1, ((point.longitude - lineStart.longitude) * dx +
                               (point.latitude  - lineStart.latitude)  * dy) / lenSq))
        let px = lineStart.longitude + t * dx - point.longitude
        let py = lineStart.latitude  + t * dy - point.latitude
        return sqrt(px * px + py * py)
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class CreateLoopViewModel {

    // Recording
    var rawWaypoints: [CLLocationCoordinate2D] = []
    var roadSegments: [[CLLocationCoordinate2D]] = []   // road-snapped coords per segment
    var isLoopClosed = false
    var isFetchingRoute = false

    // Flattened road-following coordinates across all segments
    var roadPolylineCoords: [CLLocationCoordinate2D] {
        guard !roadSegments.isEmpty else { return rawWaypoints }
        var result: [CLLocationCoordinate2D] = []
        for (i, seg) in roadSegments.enumerated() {
            result.append(contentsOf: i == 0 ? seg : Array(seg.dropFirst()))
        }
        return result
    }

    // Simplification
    var epsilon: Double = 0.0002
    var simplifiedWaypoints: [CLLocationCoordinate2D] = []

    // Stop definition
    var markedStopIndices: Set<Int> = []
    var stopNames: [Int: String] = [:]

    // Metadata form
    var routeDisplayName = ""
    var lineID = ""
    var selectedMode: TransportMode = .jeepney
    var baseFare: Double = 13
    var farePerKm: Double = 1.8
    var isAirConditioned = false
    var selectedPayments: Set<String> = ["cash"]
    var openTime = "05:00"
    var closeTime = "22:00"
    var crowdFactor: Double = 0.7
    var reliability: Double = 0.65

    // Phase & output
    var phase: CreationPhase = .recording
    var isSaving = false
    var savedSuccessfully = false
    var errorMessage: String?

    var canContinueFromRecording: Bool { rawWaypoints.count >= 3 }
    var canContinueFromStops: Bool { markedStopIndices.count >= 2 }
    var canSave: Bool { !routeDisplayName.isEmpty && !lineID.isEmpty && canContinueFromStops }

    func addWaypoint(_ coord: CLLocationCoordinate2D) async {
        guard !isLoopClosed else { return }
        let prevCoord = rawWaypoints.last
        rawWaypoints.append(coord)
        guard let from = prevCoord else { return }  // first point — no segment yet
        isFetchingRoute = true
        let segment = await fetchRoadRoute(from: from, to: coord)
        roadSegments.append(segment)
        isFetchingRoute = false
    }

    func undoLast() {
        guard !rawWaypoints.isEmpty else { return }
        rawWaypoints.removeLast()
        if !roadSegments.isEmpty { roadSegments.removeLast() }
        isLoopClosed = false
    }

    func clearAll() {
        rawWaypoints = []
        roadSegments = []
        isLoopClosed = false
    }

    func closeLoop() async {
        guard rawWaypoints.count >= 3 else { return }
        guard let first = rawWaypoints.first, let last = rawWaypoints.last else { return }
        isFetchingRoute = true
        let segment = await fetchRoadRoute(from: last, to: first)
        roadSegments.append(segment)
        isFetchingRoute = false
        isLoopClosed = true
    }

    func applySimplification() {
        // Simplify the road-following path, not just the sparse tap points
        simplifiedWaypoints = RDPSimplifier.simplify(roadPolylineCoords, epsilon: epsilon)
        markedStopIndices = []
        stopNames = [:]
    }

    func toggleStop(at index: Int) {
        if markedStopIndices.contains(index) {
            markedStopIndices.remove(index)
            stopNames.removeValue(forKey: index)
        } else {
            markedStopIndices.insert(index)
            stopNames[index] = stopNames[index] ?? "Stop \(markedStopIndices.count)"
        }
    }

    func updateRouteDisplayName(_ name: String) {
        routeDisplayName = name
        if lineID.isEmpty || autoLineID(from: routeDisplayName.dropLast()) == lineID {
            lineID = autoLineID(from: name)
        }
    }

    private func autoLineID(from name: some StringProtocol) -> String {
        String(name).uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Road snapping

    // RDP keeps exact original points, so each simplified coord has an exact match in road.
    private func nearestRoadIndex(for simplified: CLLocationCoordinate2D, in road: [CLLocationCoordinate2D]) -> Int {
        road.indices.min(by: {
            let a = road[$0]; let b = road[$1]
            let da = (a.latitude - simplified.latitude) * (a.latitude - simplified.latitude)
                   + (a.longitude - simplified.longitude) * (a.longitude - simplified.longitude)
            let db = (b.latitude - simplified.latitude) * (b.latitude - simplified.latitude)
                   + (b.longitude - simplified.longitude) * (b.longitude - simplified.longitude)
            return da < db
        }) ?? 0
    }

    private func fetchRoadRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            if let route = response.routes.first {
                return route.polyline.coordinates
            }
        } catch {}
        // Fallback: straight line between the two points
        return [from, to]
    }

    // MARK: - Save

    func generateAndSave() async {
        guard canSave else {
            errorMessage = "Fill in all required fields and mark at least 2 stops."
            return
        }
        isSaving = true
        errorMessage = nil

        let orderedIndices = markedStopIndices.sorted()
        let road = roadPolylineCoords

        // Map each stop's simplified-waypoint position to its nearest index in the full
        // road-following path. RDP only removes points, so each simplified coord is
        // an exact match for a point in roadPolylineCoords.
        let roadStopIndices: [Int] = orderedIndices.map { si in
            nearestRoadIndex(for: simplifiedWaypoints[si], in: road)
        }

        // Build station dicts (coordinates come from simplified waypoints — the user-marked spots)
        var stationDicts: [[String: Any]] = []
        for (i, idx) in orderedIndices.enumerated() {
            let coord = simplifiedWaypoints[idx]
            let name = stopNames[idx] ?? "Stop \(i + 1)"
            let shortName = name.components(separatedBy: .whitespaces).prefix(2).joined(separator: " ")
            let stationDict: [String: Any] = [
                "id":            stationID(for: i),
                "name":          name,
                "shortName":     shortName,
                "line":          lineID,
                "type":          selectedMode.rawValue,
                "coordinates":   ["lat": coord.latitude, "lng": coord.longitude],
                "isTerminal":    (i == 0 || i == orderedIndices.count - 1),
                "isInterchange": false,
                "amenities":     [String](),
                "operatingHours": ["open": openTime, "close": closeTime]
            ]
            stationDicts.append(stationDict)
        }

        // Build edge dicts using full road-following coordinates per segment.
        // polylineCoordinates slices come from roadPolylineCoords (not simplified waypoints)
        // so ExploreView sees the exact road path recorded by the user.
        var edgeDicts: [[String: Any]] = []
        let count = orderedIndices.count
        for i in 0..<count {
            let fromRoad = roadStopIndices[i]
            let toRoad   = i + 1 < count ? roadStopIndices[i + 1] : roadStopIndices[0]

            var polySlice: [[String: Double]]
            if i + 1 < count && fromRoad <= toRoad {
                polySlice = (fromRoad...toRoad).map { j in
                    ["lat": road[j].latitude, "lng": road[j].longitude]
                }
            } else {
                // Wrap-around: either the closing segment or (edge case) indices reversed
                let safeFrom = fromRoad < road.count ? fromRoad : road.count - 1
                let safeTo   = toRoad < road.count   ? toRoad   : 0
                let tail = (safeFrom..<road.count).map { j in
                    ["lat": road[j].latitude, "lng": road[j].longitude]
                }
                let head = (0...safeTo).map { j in
                    ["lat": road[j].latitude, "lng": road[j].longitude]
                }
                polySlice = tail + Array(head.dropFirst())
            }

            // Calculate rough distance (straight-line haversine sum)
            var dist = 0.0
            for k in 1..<polySlice.count {
                dist += haversine(
                    lat1: polySlice[k-1]["lat"]!, lng1: polySlice[k-1]["lng"]!,
                    lat2: polySlice[k]["lat"]!,   lng2: polySlice[k]["lng"]!
                )
            }
            let travelTime = max(2.0, dist / 0.4) // ~24 km/h average

            let edgeDict: [String: Any] = [
                "id":                    "\(lineID)_SEG\(i + 1)",
                "from":                  stationID(for: i),
                "to":                    stationID(for: (i + 1) % count),
                "mode":                  selectedMode.rawValue,
                "line":                  lineID,
                "travelTimeMinutes":     round(travelTime * 10) / 10,
                "distanceKm":            round(dist * 100) / 100,
                "baseFare":              baseFare,
                "farePerKm":             farePerKm,
                "acceptedPayments":      Array(selectedPayments),
                "isAirConditioned":      isAirConditioned,
                "crowdFactor":           crowdFactor,
                "reliability":           reliability,
                "bidirectional":         false,
                "isRoadSnapped":         true,
                "polylineCoordinates":   polySlice,
                "mkDirectionsTransportType": "automobile"
            ]
            edgeDicts.append(edgeDict)
        }

        // Write to Documents
        do {
            try await writeToGraph(stations: stationDicts, edges: edgeDicts)
            savedSuccessfully = true
            phase = .output
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func stationID(for stopIndex: Int) -> String {
        "\(lineID)_STOP\(stopIndex + 1)"
    }

    private func haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLng/2) * sin(dLng/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func writeToGraph(stations: [[String: Any]], edges: [[String: Any]]) async throws {
        guard let docsURL = GraphLoader.documentsURL(),
              FileManager.default.fileExists(atPath: docsURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let sourceURL = docsURL

        let data = try Data(contentsOf: sourceURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }

        var existingStations = root["stations"] as? [[String: Any]] ?? []
        var existingEdges    = root["edges"]    as? [[String: Any]] ?? []
        existingStations.append(contentsOf: stations)
        existingEdges.append(contentsOf: edges)
        root["stations"] = existingStations
        root["edges"]    = existingEdges

        // Append lineID to the relevant mode's lines array
        let modeKey = selectedMode.rawValue
        if var modes = root["transportModes"] as? [String: Any],
           var modeEntry = modes[modeKey] as? [String: Any],
           var lines = modeEntry["lines"] as? [String],
           !lines.contains(lineID) {
            lines.append(lineID)
            modeEntry["lines"] = lines
            modes[modeKey] = modeEntry
            root["transportModes"] = modes
        }

        let outData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outData.write(to: docsURL, options: .atomic)

        NotificationCenter.default.post(name: Notification.Name("TransitDataDidUpdate"), object: nil)
    }
}

// MARK: - Tappable Map View

final class LoopMapDelegate: NSObject, MKMapViewDelegate {
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onAnnotationTap: ((Int) -> Void)?

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let poly = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: poly)
            if poly.title == "simplified" {
                r.strokeColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
                r.lineWidth = 4
            } else {
                r.strokeColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.5)
                r.lineWidth = 3
                r.lineDashPattern = [6, 4]
            }
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let point = annotation as? MKPointAnnotation else { return nil }
        let id = "waypoint"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation

        _ = Int(point.subtitle ?? "") ?? -1   // subtitle carries the tap-delegate index
        let isStop = point.title?.hasPrefix("●") == true

        let size: CGFloat = isStop ? 18 : 10
        let color: UIColor = isStop
            ? UIColor(red: 0.95, green: 0.35, blue: 0.10, alpha: 1)
            : UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.85)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            color.setFill()
            UIColor.white.setStroke()
            let rect = CGRect(x: 1, y: 1, width: size-2, height: size-2)
            let path = UIBezierPath(ovalIn: rect)
            path.fill()
            path.lineWidth = 2
            path.stroke()
        }
        view.image = img
        view.centerOffset = CGPoint(x: 0, y: -(size/2))
        view.canShowCallout = isStop
        view.isUserInteractionEnabled = true
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let point = view.annotation as? MKPointAnnotation,
              let idxStr = point.subtitle, let idx = Int(idxStr) else { return }
        mapView.deselectAnnotation(view.annotation, animated: false)
        onAnnotationTap?(idx)
    }
}

struct TappableMapView: UIViewRepresentable {
    let phase: CreationPhase
    let rawWaypoints: [CLLocationCoordinate2D]
    let roadPolylineCoords: [CLLocationCoordinate2D]   // road-snapped path for recording phase
    let simplifiedWaypoints: [CLLocationCoordinate2D]
    let markedStopIndices: Set<Int>
    let isLoopClosed: Bool
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onAnnotationTap: ((Int) -> Void)?

    func makeCoordinator() -> LoopMapDelegate { LoopMapDelegate() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(LoopMapDelegate.handleTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        context.coordinator.onMapTap = { coord in onMapTap?(coord) }
        context.coordinator.onAnnotationTap = { idx in onAnnotationTap?(idx) }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 14.5763, longitude: 121.0194),
            span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
        )
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onMapTap        = { coord in onMapTap?(coord) }
        context.coordinator.onAnnotationTap = { idx in onAnnotationTap?(idx) }

        // Disable tap in non-recording phases; enable annotation tap in definingStops
        let taps = map.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        taps.forEach { $0.isEnabled = phase == .recording }

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        switch phase {
        case .recording:
            drawRaw(map)
        case .reviewing:
            drawSimplified(map)
        case .definingStops:
            drawRoadPolyline(map)
            addWaypointAnnotations(map)
        default:
            break
        }
    }

    private func drawRaw(_ map: MKMapView) {
        // Use road-snapped coordinates so the polyline follows actual roads.
        // Fall back to raw tap points if no road segments are available yet.
        let coords = roadPolylineCoords.count >= 2 ? roadPolylineCoords : rawWaypoints
        guard coords.count >= 2 else {
            addWaypointDots(map, points: rawWaypoints, title: nil)
            return
        }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        poly.title = "raw"
        map.addOverlay(poly)
        addWaypointDots(map, points: rawWaypoints, title: nil)
    }

    // Draws the full road-snapped polyline (used in definingStops so the route follows roads,
    // not the sparse simplified points that serve only as tappable stop candidates).
    private func drawRoadPolyline(_ map: MKMapView) {
        let coords = roadPolylineCoords.count >= 2 ? roadPolylineCoords : simplifiedWaypoints
        let loop = coords + (coords.first.map { [$0] } ?? [])
        guard loop.count >= 2 else { return }
        let poly = MKPolyline(coordinates: loop, count: loop.count)
        poly.title = "simplified"
        map.addOverlay(poly)
    }

    private func drawSimplified(_ map: MKMapView) {
        let coords = simplifiedWaypoints.isEmpty ? roadPolylineCoords : simplifiedWaypoints
        let loop = coords + (coords.first.map { [$0] } ?? [])
        guard loop.count >= 2 else { return }
        let poly = MKPolyline(coordinates: loop, count: loop.count)
        poly.title = "simplified"
        map.addOverlay(poly)
    }

    private func addWaypointAnnotations(_ map: MKMapView) {
        let pts = simplifiedWaypoints.isEmpty ? roadPolylineCoords : simplifiedWaypoints
        for (i, coord) in pts.enumerated() {
            let ann = MKPointAnnotation()
            ann.coordinate = coord
            ann.subtitle = "\(i)"
            ann.title = markedStopIndices.contains(i) ? "● Stop \(i)" : "○ \(i)"
            map.addAnnotation(ann)
        }
    }

    private func addWaypointDots(_ map: MKMapView, points: [CLLocationCoordinate2D], title: String?) {
        for (i, coord) in points.enumerated() {
            let ann = MKPointAnnotation()
            ann.coordinate = coord
            ann.subtitle = "\(i)"
            ann.title = title ?? "○ \(i)"
            map.addAnnotation(ann)
        }
    }
}

// MARK: Tap handler (needs to be in extension for @objc)
extension LoopMapDelegate {
    @objc func handleTap(_ gr: UITapGestureRecognizer) {
        guard let map = gr.view as? MKMapView else { return }
        let pt = gr.location(in: map)
        let coord = map.convert(pt, toCoordinateFrom: map)
        onMapTap?(coord)
    }
}

// MARK: - CreateLoopView

struct CreateLoopView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CreateLoopViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                switch vm.phase {
                case .recording:      RecordingPhaseView(vm: vm)
                case .reviewing:      ReviewingPhaseView(vm: vm)
                case .definingStops:  DefiningStopsPhaseView(vm: vm)
                case .fillingMetadata: MetadataPhaseView(vm: vm)
                case .output:         OutputPhaseView(vm: vm, dismiss: dismiss)
                }
            }
            .navigationTitle(phaseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if vm.phase != .output {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var phaseTitle: String {
        switch vm.phase {
        case .recording:       return "Draw Loop"
        case .reviewing:       return "Simplify Route"
        case .definingStops:   return "Mark Stops"
        case .fillingMetadata: return "Route Details"
        case .output:          return "Route Added"
        }
    }
}

// MARK: - Recording Phase

private struct RecordingPhaseView: View {
    @Bindable var vm: CreateLoopViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            TappableMapView(
                phase: .recording,
                rawWaypoints: vm.rawWaypoints,
                roadPolylineCoords: vm.roadPolylineCoords,
                simplifiedWaypoints: [],
                markedStopIndices: [],
                isLoopClosed: vm.isLoopClosed,
                onMapTap: { coord in
                    guard !vm.isFetchingRoute else { return }
                    Task { await vm.addWaypoint(coord) }
                }
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                // Status
                HStack(spacing: 8) {
                    if vm.isFetchingRoute {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: vm.isLoopClosed ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(vm.isLoopClosed ? .green : .secondary)
                    }
                    Text(vm.isFetchingRoute
                         ? "Snapping to road…"
                         : vm.isLoopClosed
                         ? "\(vm.rawWaypoints.count) points — loop closed"
                         : "\(vm.rawWaypoints.count) points — tap roads to add")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                // Controls
                HStack(spacing: 10) {
                    Button(action: vm.undoLast) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.rawWaypoints.isEmpty || vm.isFetchingRoute)

                    Button(action: vm.clearAll) {
                        Label("Clear", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.rawWaypoints.isEmpty || vm.isFetchingRoute)

                    if !vm.isLoopClosed {
                        Button {
                            Task { await vm.closeLoop() }
                        } label: {
                            Label("Close", systemImage: "arrow.triangle.branch")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(vm.rawWaypoints.count < 3 || vm.isFetchingRoute)
                    } else {
                        Button {
                            vm.applySimplification()
                            vm.phase = .reviewing
                        } label: {
                            Label("Continue", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isFetchingRoute)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Reviewing Phase

private struct ReviewingPhaseView: View {
    @Bindable var vm: CreateLoopViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            TappableMapView(
                phase: .reviewing,
                rawWaypoints: vm.rawWaypoints,
                roadPolylineCoords: vm.roadPolylineCoords,
                simplifiedWaypoints: vm.simplifiedWaypoints,
                markedStopIndices: [],
                isLoopClosed: vm.isLoopClosed
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coordinate Precision")
                                .font(.subheadline.bold())
                            Text("Original: \(vm.roadPolylineCoords.count) pts  →  Simplified: \(vm.simplifiedWaypoints.count) pts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Text("Fewer").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $vm.epsilon, in: 0.00005...0.001, step: 0.00005)
                            .onChange(of: vm.epsilon) { _, _ in vm.applySimplification() }
                        Text("More").font(.caption2).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            vm.phase = .recording
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            vm.phase = .definingStops
                        } label: {
                            Label("Continue", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Defining Stops Phase

private struct DefiningStopsPhaseView: View {
    @Bindable var vm: CreateLoopViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            TappableMapView(
                phase: .definingStops,
                rawWaypoints: vm.rawWaypoints,
                roadPolylineCoords: vm.roadPolylineCoords,
                simplifiedWaypoints: vm.simplifiedWaypoints,
                markedStopIndices: vm.markedStopIndices,
                isLoopClosed: vm.isLoopClosed,
                onAnnotationTap: { idx in vm.toggleStop(at: idx) }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Instruction pill
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                    Text("Tap dots on the map to mark named stops")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)

                // Stop list
                if !vm.markedStopIndices.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.markedStopIndices.sorted(), id: \.self) { idx in
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.orange)
                                    TextField("Stop name", text: Binding(
                                        get: { vm.stopNames[idx] ?? "Stop \(idx + 1)" },
                                        set: { vm.stopNames[idx] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: -2)
                }

                HStack(spacing: 10) {
                    Button { vm.phase = .reviewing } label: {
                        Label("Back", systemImage: "chevron.left").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { vm.phase = .fillingMetadata } label: {
                        Label("Continue", systemImage: "chevron.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canContinueFromStops)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Metadata Phase

private struct MetadataPhaseView: View {
    @Bindable var vm: CreateLoopViewModel

    private let paymentOptions = ["cash", "gcash", "maya", "beep_card", "card"]

    var body: some View {
        Form {
            Section("Route Identity") {
                TextField("Display Name", text: Binding(
                    get: { vm.routeDisplayName },
                    set: { vm.updateRouteDisplayName($0) }
                ))

                HStack {
                    Text("Line ID")
                    Spacer()
                    TextField("LINE_ID", text: $vm.lineID)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Transport") {
                Picker("Mode", selection: $vm.selectedMode) {
                    ForEach([TransportMode.jeepney, .bus, .tricycle, .train], id: \.self) { m in
                        Text(m.rawValue.capitalized).tag(m)
                    }
                }
                Toggle("Air Conditioned", isOn: $vm.isAirConditioned)
            }

            Section("Fare") {
                HStack {
                    Text("Base Fare (₱)")
                    Spacer()
                    TextField("13", value: $vm.baseFare, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Per km (₱)")
                    Spacer()
                    TextField("1.80", value: $vm.farePerKm, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Accepted Payments") {
                ForEach(paymentOptions, id: \.self) { p in
                    Toggle(p.replacingOccurrences(of: "_", with: " ").capitalized,
                           isOn: Binding(
                            get: { vm.selectedPayments.contains(p) },
                            set: { on in
                                if on { vm.selectedPayments.insert(p) }
                                else  { vm.selectedPayments.remove(p) }
                            }
                           ))
                }
            }

            Section("Operating Hours") {
                HStack {
                    Text("Opens")
                    Spacer()
                    TextField("05:00", text: $vm.openTime)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Closes")
                    Spacer()
                    TextField("22:00", text: $vm.closeTime)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Quality") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crowd Factor: \(String(format: "%.2f", vm.crowdFactor))")
                        .font(.subheadline)
                    Slider(value: $vm.crowdFactor, in: 0...1, step: 0.05)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reliability: \(String(format: "%.2f", vm.reliability))")
                        .font(.subheadline)
                    Slider(value: $vm.reliability, in: 0...1, step: 0.05)
                }
            }

            Section {
                Button { vm.phase = .definingStops } label: {
                    Label("Back", systemImage: "chevron.left")
                }

                Button {
                    Task { await vm.generateAndSave() }
                } label: {
                    if vm.isSaving {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Saving…")
                        }
                    } else {
                        Label("Save & Add Route", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(vm.canSave ? Color.blue : Color.gray)
                .foregroundStyle(.white)
                .disabled(!vm.canSave || vm.isSaving)
            }

            if let err = vm.errorMessage {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }
}

// MARK: - Output Phase

private struct OutputPhaseView: View {
    let vm: CreateLoopViewModel
    let dismiss: DismissAction

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("Route Added!")
                    .font(.title2.bold())
                Text(vm.routeDisplayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("\(vm.markedStopIndices.count) stops · \(vm.markedStopIndices.count) edges")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("The route has been saved to transit_graph_v3.json.\nThe Explore tab will show it after reloading.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
        }
    }
}
