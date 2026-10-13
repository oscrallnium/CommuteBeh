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
    case directionPicker, recording, reviewing, definingStops, offerSecondPass, fillingMetadata, output
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

    /// A single recorded pass through the route — either the whole (direction-less)
    /// route, or one of an optional northbound/southbound pair. Snapshotted from the
    /// live recording state in `finishCurrentPass()`; independent per direction, since
    /// real-world jeepney/bus stops on opposite one-way streets are usually physically
    /// different corners, not the same shared station a train uses for both directions.
    struct RecordedPass {
        var direction: String?
        var roadPolylineCoords: [CLLocationCoordinate2D]
        var placedStops: [PlacedStop]
        var isLoopClosed: Bool
        /// Always true: `fetchRoadRoute` has no straight-line fallback, so a pass can
        /// only contain MKDirections geometry — a failed snap discards the tap instead
        /// of substituting a chord. Kept as a stored field because it is part of the
        /// wire format, and tells the backend/Explore this polyline can be trusted
        /// directly instead of being silently re-computed and discarded.
        var isRoadSnapped: Bool
    }

    /// A stop placed at an arbitrary point along the recorded path — not constrained
    /// to one of the RDP-simplified shape points. Tapping anywhere near the drawn
    /// route snaps to the nearest point on the full-resolution road polyline, so a
    /// stop can go between any two existing waypoints, not only on top of one.
    struct PlacedStop: Identifiable, Equatable {
        let id = UUID()
        var coordinate: CLLocationCoordinate2D
        var name: String
        /// Fractional index along the pass's road polyline (segment index + how far
        /// along it), fixed at the moment the stop is placed.
        ///
        /// Deliberately stored rather than re-derived on demand: on a route that doubles
        /// back along the same corridor, a return-side stop projects just as well onto
        /// the outbound trace running beside it, so re-projecting later would silently
        /// reorder the chain — and did, both in the editing list and in the saved payload.
        var position: Double

        static func == (lhs: PlacedStop, rhs: PlacedStop) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.position == rhs.position
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    // Direction / multi-pass
    var currentPassDirection: String?
    var completedPasses: [RecordedPass] = []

    // Recording (live, in-progress pass)
    var rawWaypoints: [CLLocationCoordinate2D] = []
    var roadSegments: [[CLLocationCoordinate2D]] = []   // road-snapped coords per segment
    var isLoopClosed = false
    var isFetchingRoute = false
    var roadFetchError: String?
    // Flattened road-following coordinates across all segments
    var roadPolylineCoords: [CLLocationCoordinate2D] {
        guard !roadSegments.isEmpty else { return rawWaypoints }
        var result: [CLLocationCoordinate2D] = []
        for (i, seg) in roadSegments.enumerated() {
            result.append(contentsOf: i == 0 ? seg : Array(seg.dropFirst()))
        }
        return result
    }

    // Simplification (display precision only — the saved edge polylines are always
    // sliced from the full-resolution roadPolylineCoords, not this)
    var epsilon: Double = 0.0002
    var simplifiedWaypoints: [CLLocationCoordinate2D] = []

    // Stop definition — freely placed along the path, not tied to simplifiedWaypoints
    var placedStops: [PlacedStop] = []

    /// Normally each new stop is snapped to the path *at or after* the last one placed,
    /// so marking stops in travel order can't land a return-side stop on the outbound
    /// trace beside it. Turning this on lifts that constraint for the occasional
    /// out-of-order correction.
    var placeAnywhereAlongPath = false

    /// Set when a tap in the Mark Stops phase couldn't become a stop. Cleared by the next
    /// attempt, or by the admin dismissing it.
    var stopPlacementError: String?

    /// True when the recorded path passes close to itself at two well-separated points —
    /// an out-and-back or a loop. Computed once when the recording is finished rather
    /// than per redraw, since it walks the full-resolution polyline.
    var pathDoublesBack = false

    /// Whether the route is served in the recorded direction only. Sent to the backend as
    /// `bidirectional: !isOneWay`.
    ///
    /// Defaults to one-way because a traced recording *is* a direction of travel and its
    /// stops sit on one side of the road; a reverse edge over those same stops is what
    /// lets the router tell a homebound rider to alight on the outbound side. Two-way is
    /// the special case — the same physical stop serving both directions.
    var isOneWay = true

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
    var phase: CreationPhase = .directionPicker
    var isSaving = false
    var savedSuccessfully = false
    var errorMessage: String?
    var savedResult: CreateRouteResult?

    /// True once any recorded pass carries a direction — those are one-way by definition,
    /// so the one-way toggle has nothing to decide.
    var hasDirectionalPass: Bool {
        currentPassDirection != nil || completedPasses.contains { $0.direction != nil }
    }

    var canContinueFromRecording: Bool { rawWaypoints.count >= 3 }
    var canContinueFromStops: Bool { placedStops.count >= 2 }
    var canSave: Bool {
        !routeDisplayName.isEmpty && !lineID.isEmpty && !completedPasses.isEmpty
            && completedPasses.allSatisfy { $0.placedStops.count >= 2 }
            && lineIdStatus?.isBlocking != true
    }

    // MARK: - Existing-route append detection
    //
    // Mirrors the backend's `existing_line_append_error`: if the entered Line ID
    // already has stations/edges, the only thing this session is allowed to do is
    // add the one missing direction — never for train mode (MRT/LRT stations are
    // shared by both directions already, and those lines aren't authored here).

    struct ExistingLineInfo {
        let mode: String
        let directions: Set<String>
    }

    var existingLineMatch: ExistingLineInfo? {
        guard !lineID.isEmpty, case .success(let graph) = GraphLoader.load() else { return nil }
        let stations = graph.stations.filter { $0.line == lineID }
        guard let mode = stations.first?.type else { return nil }
        let directions = Set(graph.edges.filter { $0.line == lineID }.compactMap(\.direction))
        return ExistingLineInfo(mode: mode, directions: directions)
    }

    /// A human-readable status for the Line ID field, and whether it blocks saving.
    /// `isBlocking == false` means this is a valid "add the missing direction to an
    /// existing route" append — still shown to the admin so Save can ask for
    /// confirmation before actually appending to someone else's existing route.
    var lineIdStatus: (message: String, isBlocking: Bool)? {
        guard let match = existingLineMatch else { return nil }
        if match.mode == "train" {
            return ("Train lines can't be extended via Add Route — pick a different Line ID.", true)
        }
        if match.directions.isEmpty {
            return ("This Line ID already exists (recorded without a direction) — pick a different Line ID.", true)
        }
        let newDirections = Set(completedPasses.compactMap(\.direction))
        if newDirections.isEmpty {
            return ("This Line ID already exists — pick a different Line ID, or record a Northbound/Southbound direction to add it to that route.", true)
        }
        if let collision = newDirections.intersection(match.directions).first {
            return ("\(collision.capitalized) already exists for this route — pick a different Line ID.", true)
        }
        let existingLabel = match.directions.sorted().map { $0.capitalized }.joined(separator: ", ")
        return ("Adds to the existing route (currently: \(existingLabel)).", false)
    }

    // MARK: - Direction / multi-pass flow

    func chooseDirection(_ direction: String?) {
        currentPassDirection = direction
        phase = .recording
    }

    /// Snapshots the just-finished pass and decides what's next: if this pass had a
    /// direction and its opposite hasn't been recorded yet, offer to record it too
    /// (optional — matches the "not an absolute rule" ask); otherwise go straight to
    /// the shared route-details form.
    func finishCurrentPass() {
        completedPasses.append(RecordedPass(
            direction: currentPassDirection,
            roadPolylineCoords: roadPolylineCoords,
            placedStops: placedStops,
            isLoopClosed: isLoopClosed,
            isRoadSnapped: true
        ))

        if remainingDirection != nil {
            phase = .offerSecondPass
        } else {
            phase = .fillingMetadata
        }
    }

    /// The one direction not yet recorded, if the current pass set was directional and
    /// incomplete — nil once both northbound and southbound are present, or if the only
    /// pass so far had no direction at all (a direction-less route never offers a second pass).
    var remainingDirection: String? {
        let recorded = Set(completedPasses.compactMap(\.direction))
        if recorded.contains("northbound") && !recorded.contains("southbound") { return "southbound" }
        if recorded.contains("southbound") && !recorded.contains("northbound") { return "northbound" }
        return nil
    }

    func startSecondPass() {
        guard let direction = remainingDirection else { return }
        rawWaypoints = []
        roadSegments = []
        isLoopClosed = false
        simplifiedWaypoints = []
        placedStops = []
        roadFetchError = nil
        currentPassDirection = direction
        phase = .recording
    }

    func skipSecondPass() {
        phase = .fillingMetadata
    }

    /// Navigating back from the metadata form to re-edit stops must undo the snapshot
    /// `finishCurrentPass()` took, or resuming forward would append a duplicate copy of
    /// the same pass. The live in-progress properties (`placedStops` etc.) are
    /// untouched by that snapshot, so popping it and re-entering `.definingStops` lands
    /// back exactly where editing left off.
    func backToDefiningStopsFromMetadata() {
        if !completedPasses.isEmpty {
            completedPasses.removeLast()
        }
        phase = .definingStops
    }

    func addWaypoint(_ coord: CLLocationCoordinate2D) async {
        guard !isLoopClosed else { return }
        let prevCoord = rawWaypoints.last
        rawWaypoints.append(coord)
        guard let from = prevCoord else { return }  // first point — no segment yet
        isFetchingRoute = true
        guard let segment = await fetchRoadRoute(from: from, to: coord) else {
            // The tap is rolled back with the failed segment. Keeping it would leave
            // rawWaypoints one ahead of roadSegments, and `roadPolylineCoords` stitches
            // segments end to end assuming they're consecutive — so every later segment
            // would be joined to the wrong neighbour, drawing a path that was never
            // recorded. Dropping the tap keeps the two arrays in lockstep.
            rawWaypoints.removeLast()
            isFetchingRoute = false
            return
        }
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
        // No closing segment means the loop stays open rather than being closed with a
        // chord straight across the map. The error banner says why; the admin can move
        // the last point and try again.
        guard let segment = await fetchRoadRoute(from: last, to: first) else {
            isFetchingRoute = false
            return
        }
        roadSegments.append(segment)
        isFetchingRoute = false
        isLoopClosed = true
    }

    func applySimplification() {
        // Simplify the road-following path, not just the sparse tap points. Display-only —
        // reached before any stops exist yet, so there's nothing here to preserve/clear.
        simplifiedWaypoints = RDPSimplifier.simplify(roadPolylineCoords, epsilon: epsilon)
        pathDoublesBack = Self.detectDoublingBack(roadPolylineCoords)
    }

    /// True when two points of the path lie within `proximityMeters` of each other while
    /// being at least `separationMeters` apart *along* the path — i.e. the route comes
    /// back to a road it already used. Buckets coordinates into a coarse grid so this is
    /// a linear scan rather than an all-pairs comparison.
    static func detectDoublingBack(
        _ road: [CLLocationCoordinate2D],
        proximityMeters: Double = 25,
        separationMeters: Double = 300
    ) -> Bool {
        guard road.count > 4 else { return false }

        var cumulative = [Double](repeating: 0, count: road.count)
        for i in 1..<road.count {
            cumulative[i] = cumulative[i - 1] + CLLocation(latitude: road[i - 1].latitude, longitude: road[i - 1].longitude)
                .distance(from: CLLocation(latitude: road[i].latitude, longitude: road[i].longitude))
        }

        // ~27 m at this latitude — one cell, so a near-miss is always in the 3×3 around it.
        let cell = 0.00025
        var buckets: [Int64: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) &* 1_000_003 &+ Int64(y) }

        for (i, coord) in road.enumerated() {
            let gx = Int((coord.latitude / cell).rounded(.down))
            let gy = Int((coord.longitude / cell).rounded(.down))
            let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            for dx in -1...1 {
                for dy in -1...1 {
                    for j in buckets[key(gx + dx, gy + dy)] ?? [] {
                        guard cumulative[i] - cumulative[j] > separationMeters else { continue }
                        let other = CLLocation(latitude: road[j].latitude, longitude: road[j].longitude)
                        if here.distance(from: other) < proximityMeters { return true }
                    }
                }
            }
            buckets[key(gx, gy), default: []].append(i)
        }
        return false
    }

    /// Places a new stop at the point on the full-resolution road polyline nearest the
    /// tapped coordinate — anywhere along the recorded path (projected onto the nearest
    /// line segment, not just the nearest existing vertex), not only at one of the
    /// sparse RDP-simplified shape points. Falls back to the raw tapped coordinate if
    /// there's no road polyline to snap to yet.
    func addStop(at coordinate: CLLocationCoordinate2D) {
        stopPlacementError = nil
        let road = roadPolylineCoords
        let lastPosition = placedStops.map(\.position).max() ?? 0
        guard road.count >= 2 else {
            placedStops.append(PlacedStop(coordinate: coordinate,
                                          name: "Stop \(placedStops.count + 1)",
                                          position: lastPosition + 1))
            return
        }
        // Where the route passes near this tap — one entry per pass, in path order. An
        // out-and-back circuit passes the same spot twice, so a tap there is genuinely
        // ambiguous and the tap alone can't settle it.
        let candidates = roadPointsNear(coordinate, road: road, within: Self.maxStopSnapMeters)
        guard !candidates.isEmpty else {
            stopPlacementError = "No stop was added — that point is too far from the route. Tap on the blue line."
            return
        }

        // Take the *earliest* pass at or after the last stop — not the closest.
        //
        // Picking the closest and then clamping it forward is what broke this: at the
        // terminal, where the outbound and return lanes meet, the return lane can be a
        // metre nearer, so the very first stop snapped to the *end* of the route. The
        // forward floor then sat on the final segment and every later tap projected onto
        // it, so an entire route's stops came out sharing one coordinate. Choosing the
        // earliest eligible pass puts that first stop at the start where it belongs, and
        // still sends a return-side stop to the return lane once the floor is past the loop.
        let eligible = placeAnywhereAlongPath ? candidates : candidates.filter { $0.position >= lastPosition }
        guard let chosen = eligible.first else {
            stopPlacementError = "No stop was added — that point comes before the last stop you placed. Tap further along the route, or switch on “Place anywhere”."
            return
        }

        placedStops.append(PlacedStop(coordinate: chosen.coordinate,
                                      name: "Stop \(placedStops.count + 1)",
                                      position: chosen.position))
    }

    /// How far a tap may sit from the point it snaps to before the placement is refused.
    /// Generous enough for an imprecise tap on a zoomed-out map, tight enough that a stop
    /// never lands somewhere the admin isn't looking.
    private static let maxStopSnapMeters: CLLocationDistance = 200

    private static func metres(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    func removeStop(id: PlacedStop.ID) {
        placedStops.removeAll { $0.id == id }
    }

    func renameStop(id: PlacedStop.ID, to newName: String) {
        guard let idx = placedStops.firstIndex(where: { $0.id == id }) else { return }
        placedStops[idx].name = newName
    }

    /// Stops in path order — matches the order they'll be saved in, so the editing list
    /// reads the same as the finished route. Sorts on each stop's stored `position`
    /// rather than re-projecting: see `PlacedStop.position`.
    var orderedPlacedStops: [PlacedStop] {
        placedStops.sorted { $0.position < $1.position }
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

    /// The closest point ON the road polyline to an arbitrary coordinate — projected
    /// onto whichever line *segment* (between two consecutive recorded points) is
    /// nearest, not merely snapped to the closest existing vertex. Snapping to the
    /// nearest vertex alone is what caused a tapped-to-add stop to visibly land away
    /// from the actual tap point whenever recorded points were sparse (e.g. a long
    /// straight MKDirections-snapped stretch) — this always lands exactly on the
    /// drawn line, at the point nearest the tap.
    ///
    /// `position` is a fractional index (segment `i` + how far along it, 0...1),
    /// used to order stops along the path and to slice the polyline between them.
    struct RoadPoint {
        let coordinate: CLLocationCoordinate2D
        let position: Double
    }

    /// Every place the path comes within `radius` of `point`, in path order — one entry
    /// per pass, so a circuit that runs the same road twice yields two.
    ///
    /// A single "nearest point" can't describe a self-intersecting route: at a terminal
    /// the two lanes are metres apart, and which one wins is a coin toss decided by
    /// survey noise. Returning every pass lets the caller choose on travel order instead,
    /// which is information the tap doesn't carry.
    ///
    /// Runs of consecutive segments within the radius collapse to their closest point, so
    /// one approach yields one candidate rather than one per segment.
    func roadPointsNear(
        _ point: CLLocationCoordinate2D,
        road: [CLLocationCoordinate2D],
        within radius: CLLocationDistance
    ) -> [RoadPoint] {
        guard road.count >= 2 else { return [] }

        var candidates: [RoadPoint] = []
        var runBest: (point: RoadPoint, distance: CLLocationDistance)?

        for i in 0..<(road.count - 1) {
            let a = road[i], b = road[i + 1]
            let dx = b.longitude - a.longitude
            let dy = b.latitude - a.latitude
            let lenSq = dx * dx + dy * dy
            let t: Double = lenSq > 0
                ? max(0, min(1, ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lenSq))
                : 0
            let projected = CLLocationCoordinate2D(latitude: a.latitude + t * dy,
                                                   longitude: a.longitude + t * dx)
            let distance = Self.metres(from: point, to: projected)

            if distance <= radius {
                let here = RoadPoint(coordinate: projected, position: Double(i) + t)
                if runBest == nil || distance < runBest!.distance {
                    runBest = (here, distance)
                }
            } else if let best = runBest {
                // Left the radius — that approach is finished, keep its closest point.
                candidates.append(best.point)
                runBest = nil
            }
        }
        if let best = runBest { candidates.append(best.point) }
        return candidates
    }

    private enum RoadFetchError: LocalizedError {
        case noRoute
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noRoute:  return "no route found"
            case .timedOut: return "timed out"
            }
        }
    }

    /// Road-following coordinates between two points, or **nil** when MKDirections can't
    /// supply them.
    ///
    /// There is deliberately no straight-line fallback. Returning `[from, to]` on failure
    /// wrote a segment that cuts across whatever lies between the two taps — buildings,
    /// rivers, the wrong side of a divided road — into a route that is otherwise real
    /// recorded geometry, and nothing downstream could tell the two apart afterwards.
    /// A failure now surfaces and the tap is discarded, so every saved segment came from
    /// MKDirections.
    private func fetchRoadRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
        roadFetchError = nil
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        // MKDirections has no "shortest distance" objective — it only optimizes for
        // (traffic-aware) travel time. Requesting alternates and picking the one with the
        // smallest `distance` is the closest approximation available: it biases away from
        // MapKit's default "fastest" pick toward whichever candidate detours least.
        //
        // No plausibility-vs-straight-line rejection here (unlike an earlier version of
        // this function): jeepney/tricycle loops are drawn with taps spaced around blocks,
        // one-way streets, and turns, so real driving distance routinely exceeds straight-line
        // distance by more than 2x even for a completely correct road route. Rejecting those
        // silently discarded a valid MapKit polyline in favor of a straight-line fallback —
        // exactly the "always a straight line" symptom this was rewritten to fix. Matches the
        // sibling implementations (`ExploreView.roadPolyline`, `RecordCommuteView.roadSegment`),
        // neither of which applies this filter.
        request.requestsAlternateRoutes = true

        // Race MKDirections against a 10-second timeout so a single hanging request never
        // stalls the recording flow (same pattern as `RecordCommuteView.roadSegment` /
        // `ExploreView.roadPolyline`).
        let outcome: Result<[CLLocationCoordinate2D], Error> = await withTaskGroup(
            of: Result<[CLLocationCoordinate2D], Error>.self
        ) { group in
            group.addTask {
                do {
                    let response = try await MKDirections(request: request).calculate()
                    guard let route = response.routes.min(by: { $0.distance < $1.distance }) else {
                        return .failure(RoadFetchError.noRoute)
                    }
                    // `MKPolyline.coordinates` (this file's convenience extension) is
                    // MainActor-isolated by the module's default isolation, but this task
                    // group's child task isn't — extract manually to stay off the main actor.
                    let count = route.polyline.pointCount
                    var coords = Array(repeating: CLLocationCoordinate2D(), count: count)
                    route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                    return .success(coords)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .failure(RoadFetchError.timedOut)
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }

        switch outcome {
        case .success(let coords):
            return coords
        case .failure(let error):
            roadFetchError = "Couldn't snap to roads (\(error.localizedDescription)) — that point wasn't added. Try tapping closer to a road."
            return nil
        }
    }

    // MARK: - Save

    /// Builds the wire-format payload for one recorded pass (its stops, each carrying the
    /// polyline for the segment leading into it, plus an optional closing segment) — the
    /// shape `GraphService#add_route` expects per entry in its `passes` array.
    private func buildPassPayload(_ pass: RecordedPass) -> [String: Any] {
        let road = pass.roadPolylineCoords

        // Order by the position each stop was given when it was placed. Re-projecting here
        // instead (the previous behaviour) reintroduced the doubling-back reorder on the
        // saved payload even when the on-screen list was correct — the display and the
        // save path have to agree, so both read the stored value.
        let stopsWithPosition = pass.placedStops
            .map { ($0, $0.position) }
            .sorted { $0.1 < $1.1 }
        let orderedStops = stopsWithPosition.map(\.0)
        let stopPositions = stopsWithPosition.map(\.1)
        let count = orderedStops.count

        // Road-following polyline slice between two ordered stops, identified by their
        // fractional position along `road` (segment index + fraction, from
        // nearestPointOnRoad). Always starts/ends exactly at the stops' own (possibly
        // interpolated, between-two-vertices) coordinates — not just the nearest
        // recorded vertex — with any full vertices strictly between them preserved in
        // the middle. `closing: true` is for the wrap-around segment (last stop back to
        // the first) — always a tail+head wrap since it's the one segment that actually
        // crosses the array seam; any other `fromPos > toPos` is treated the same way as
        // a defensive fallback.
        func polySlice(from fromIdx: Int, to toIdx: Int, closing: Bool) -> [[String: Double]] {
            let fromPos = stopPositions[fromIdx]
            let toPos   = stopPositions[toIdx]
            let fromCoord = orderedStops[fromIdx].coordinate
            let toCoord   = orderedStops[toIdx].coordinate

            if !closing && fromPos <= toPos {
                var points = [fromCoord]
                let lowIdx  = Int(fromPos.rounded(.up))
                let highIdx = Int(toPos.rounded(.down))
                if lowIdx <= highIdx, road.indices.contains(lowIdx), road.indices.contains(highIdx) {
                    points.append(contentsOf: road[lowIdx...highIdx])
                }
                points.append(toCoord)
                return points.map { ["lat": $0.latitude, "lng": $0.longitude] }
            }

            var points = [fromCoord]
            let tailLow = Int(fromPos.rounded(.up))
            if road.indices.contains(tailLow) {
                points.append(contentsOf: road[tailLow...])
            }
            let headHigh = Int(toPos.rounded(.down))
            if headHigh >= 0, road.indices.contains(headHigh) {
                points.append(contentsOf: road[0...headHigh])
            }
            points.append(toCoord)
            return points.map { ["lat": $0.latitude, "lng": $0.longitude] }
        }

        var stopDicts: [[String: Any]] = []
        for (i, stop) in orderedStops.enumerated() {
            let coord = stop.coordinate
            let name = stop.name
            let shortName = name.components(separatedBy: .whitespaces).prefix(2).joined(separator: " ")
            var stopDict: [String: Any] = [
                "name": name,
                "shortName": shortName,
                "lat": coord.latitude,
                "lng": coord.longitude
            ]
            if i > 0 {
                stopDict["polyline"] = polySlice(from: i - 1, to: i, closing: false)
            }
            stopDicts.append(stopDict)
        }

        // A directional pass is always one-way — the backend rejects a direction tag
        // combined with bidirectional, since the synthetic reverse edge would carry the
        // flipped direction label. Otherwise the route-level toggle decides.
        //
        // Read from the view model rather than snapshotted onto RecordedPass (as the plan
        // first suggested): the toggle lives in the metadata form, which the admin reaches
        // *after* finishCurrentPass() takes its snapshot, so a snapshotted copy would
        // always be the default and silently ignore the choice.
        let oneWay = pass.direction != nil || isOneWay
        var passDict: [String: Any] = [
            "stops": stopDicts,
            "isRoadSnapped": pass.isRoadSnapped,
            "bidirectional": !oneWay
        ]
        if let direction = pass.direction {
            passDict["direction"] = direction
        }
        // A directional pass is a one-way leg — the UI never offers "Close Loop" once a
        // direction is chosen, so this only ever fires for a direction-less pass.
        if pass.isLoopClosed, count >= 2 {
            passDict["closesLoop"] = true
            passDict["closingPolyline"] = polySlice(from: count - 1, to: 0, closing: true)
        }
        return passDict
    }

    func generateAndSave() async {
        guard canSave else {
            errorMessage = "Fill in all required fields and mark at least 2 stops for each direction."
            return
        }
        isSaving = true
        errorMessage = nil

        let payload: [String: Any] = [
            "displayName":      routeDisplayName,
            "lineID":           lineID,
            "mode":             selectedMode.rawValue,
            "openTime":         openTime,
            "closeTime":        closeTime,
            "baseFare":         baseFare,
            "farePerKm":        farePerKm,
            "acceptedPayments": Array(selectedPayments),
            "isAirConditioned": isAirConditioned,
            "crowdFactor":      crowdFactor,
            "reliability":      reliability,
            "passes":           completedPasses.map(buildPassPayload)
        ]

        do {
            savedResult = try await AdminService.shared.createRoute(payload: payload)
            // Pull the now-updated graph (with the real station/edge IDs the server
            // assigned) into the local cache immediately, rather than waiting for the
            // next periodic syncIfNeeded — otherwise the new route wouldn't show up in
            // Explore/Commute until some unrelated graph-version check happens to run.
            await GraphService.shared.forceSync()
            savedSuccessfully = true
            phase = .output
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - Tappable Map View

final class LoopMapDelegate: NSObject, MKMapViewDelegate {
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onAnnotationTap: ((Int) -> Void)?
    var onStopTap: ((UUID) -> Void)?

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let poly = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: poly)
            if poly.title == "simplified" {
                r.strokeColor = UIColor(Color.onyx).withAlphaComponent(0.9)
                r.lineWidth = 4
            } else {
                r.strokeColor = UIColor(Color.onyx).withAlphaComponent(0.5)
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

        let isStop = point.title?.hasPrefix("●") == true

        let size: CGFloat = isStop ? 18 : 10
        let color: UIColor = isStop
            ? UIColor(Color.onyx)
            : UIColor(Color.slate).withAlphaComponent(0.85)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            color.setFill()
            UIColor(Color.canvas).setStroke()
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
        guard let point = view.annotation as? MKPointAnnotation, let subtitle = point.subtitle else { return }
        mapView.deselectAnnotation(view.annotation, animated: false)
        // `.flexible` mode annotations carry a PlacedStop UUID; `.indexed` mode annotations
        // carry a plain array-index integer — try both, since one delegate serves either.
        if let id = UUID(uuidString: subtitle) {
            onStopTap?(id)
        } else if let idx = Int(subtitle) {
            onAnnotationTap?(idx)
        }
    }
}

/// Two ways `definingStops` lets the rider mark stops:
/// - `.flexible` (Loop Creator / Add Route) — tap anywhere along the drawn path; the tap
///   snaps to the nearest point on the full-resolution road polyline, so a stop isn't
///   forced onto one of the sparse RDP-simplified shape points.
/// - `.indexed` (RecordCommuteView's separate recorded-route flow) — legacy behavior:
///   every simplified waypoint is shown as a tappable dot, toggled marked/unmarked.
enum StopAnnotationMode {
    case indexed
    case flexible
}

struct TappableMapView: UIViewRepresentable {
    let phase: CreationPhase
    let rawWaypoints: [CLLocationCoordinate2D]
    let roadPolylineCoords: [CLLocationCoordinate2D]   // road-snapped path for recording phase
    let simplifiedWaypoints: [CLLocationCoordinate2D]
    var markedStopIndices: Set<Int> = []
    var placedStops: [CreateLoopViewModel.PlacedStop] = []
    var stopAnnotationMode: StopAnnotationMode = .indexed
    let isLoopClosed: Bool
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onAnnotationTap: ((Int) -> Void)?
    var onStopTap: ((UUID) -> Void)?

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
        context.coordinator.onStopTap = { id in onStopTap?(id) }

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
        context.coordinator.onStopTap       = { id in onStopTap?(id) }

        // Tap places a waypoint in recording. In definingStops, `.flexible` mode also
        // places a new stop anywhere along the path; `.indexed` mode disables the general
        // tap and relies solely on tapping one of the pre-drawn candidate dots.
        let taps = map.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer } ?? []
        taps.forEach {
            $0.isEnabled = phase == .recording
                || (phase == .definingStops && stopAnnotationMode == .flexible)
        }

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        switch phase {
        case .recording:
            drawRaw(map)
        case .reviewing:
            drawSimplified(map)
        case .definingStops:
            drawRoadPolyline(map)
            switch stopAnnotationMode {
            case .flexible: addStopAnnotations(map)
            case .indexed:  addWaypointAnnotations(map)
            }
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
    //
    // Does NOT manually re-close the path back to the first point — `roadPolylineCoords`
    // already includes the real, road-snapped closing segment when `isLoopClosed` is true
    // (recorded via `closeLoop()`), and correctly ends open otherwise. Forcing a straight
    // line back to the start unconditionally used to draw a phantom "closing" segment even
    // for routes that were never closed (the common case now that closing is optional, and
    // for any northbound/southbound directional pass, which is inherently one-way).
    private func drawRoadPolyline(_ map: MKMapView) {
        let coords = roadPolylineCoords.count >= 2 ? roadPolylineCoords : simplifiedWaypoints
        guard coords.count >= 2 else { return }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        poly.title = "simplified"
        map.addOverlay(poly)
    }

    private func drawSimplified(_ map: MKMapView) {
        let coords = simplifiedWaypoints.isEmpty ? roadPolylineCoords : simplifiedWaypoints
        guard coords.count >= 2 else { return }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        poly.title = "simplified"
        map.addOverlay(poly)
    }

    private func addStopAnnotations(_ map: MKMapView) {
        for stop in placedStops {
            let ann = MKPointAnnotation()
            ann.coordinate = stop.coordinate
            ann.subtitle = stop.id.uuidString
            ann.title = "● \(stop.name)"
            map.addAnnotation(ann)
        }
    }

    // Legacy `.indexed` mode (RecordCommuteView): every simplified waypoint is a
    // tappable candidate dot, shown bigger/orange once marked as a stop.
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
                case .directionPicker: DirectionPickerPhaseView(vm: vm)
                case .recording:       RecordingPhaseView(vm: vm)
                case .reviewing:       ReviewingPhaseView(vm: vm)
                case .definingStops:   DefiningStopsPhaseView(vm: vm)
                case .offerSecondPass: OfferSecondPassView(vm: vm)
                case .fillingMetadata: MetadataPhaseView(vm: vm)
                case .output:          OutputPhaseView(vm: vm, dismiss: dismiss)
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
        case .directionPicker: return "Add Route"
        case .recording:       return vm.currentPassDirection?.capitalized ?? "Draw Route"
        case .reviewing:       return "Simplify Route"
        case .definingStops:   return "Mark Stops"
        case .offerSecondPass: return "Add Direction?"
        case .fillingMetadata: return "Route Details"
        case .output:          return "Route Added"
        }
    }
}

// MARK: - Direction Picker Phase

private struct DirectionPickerPhaseView: View {
    @Bindable var vm: CreateLoopViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56))
                .foregroundStyle(Color.ember)
            VStack(spacing: 8) {
                Text("Does this route run in a specific direction?")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("Optional — pick Northbound or Southbound if the route follows a different path each way (e.g. one-way streets). Otherwise just draw a single path or loop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 10) {
                Button {
                    vm.chooseDirection(nil)
                } label: {
                    Text("No Specific Direction")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button {
                        vm.chooseDirection("northbound")
                    } label: {
                        Text("Northbound").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.chooseDirection("southbound")
                    } label: {
                        Text("Southbound").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - Offer Second Pass Phase

private struct OfferSecondPassView: View {
    @Bindable var vm: CreateLoopViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.jade)
            VStack(spacing: 8) {
                Text("\(vm.currentPassDirection?.capitalized ?? "") Drawn")
                    .font(.title3.bold())
                if let remaining = vm.remainingDirection {
                    Text("Would you like to also draw \(remaining.capitalized) for this route? Optional — you can add it later by creating another route with the same Line ID.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            VStack(spacing: 10) {
                Button {
                    vm.startSecondPass()
                } label: {
                    Label("Draw \(vm.remainingDirection?.capitalized ?? "")", systemImage: "hand.tap.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    vm.skipSecondPass()
                } label: {
                    Text("Skip — Continue to Route Details")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            Spacer()
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
                placedStops: [],
                isLoopClosed: vm.isLoopClosed,
                onMapTap: { coord in
                    guard !vm.isFetchingRoute else { return }
                    Task { await vm.addWaypoint(coord) }
                }
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if let err = vm.roadFetchError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ember)
                        Text(err).font(.caption).foregroundStyle(Color.ember)
                        Button {
                            vm.roadFetchError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                }

                // Status
                HStack(spacing: 8) {
                    if vm.isFetchingRoute {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: vm.isLoopClosed ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(vm.isLoopClosed ? Color.jade : Color.secondary)
                    }
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                // Controls
                VStack(spacing: 8) {
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
                    }

                    HStack(spacing: 10) {
                        // Closing back to the start is only offered for a direction-less
                        // pass — a northbound/southbound leg is inherently one-way, so
                        // closing it wouldn't make sense. Optional either way: unlike the
                        // old flow, "Finish" is always available without closing first.
                        if vm.currentPassDirection == nil, !vm.isLoopClosed {
                            Button {
                                Task { await vm.closeLoop() }
                            } label: {
                                Label("Close Loop", systemImage: "arrow.triangle.branch")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.ember)
                            .disabled(vm.rawWaypoints.count < 3 || vm.isFetchingRoute)
                        }

                        Button {
                            vm.applySimplification()
                            vm.phase = .reviewing
                        } label: {
                            Label(vm.isLoopClosed ? "Continue" : "Finish", systemImage: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.rawWaypoints.count < 3 || vm.isFetchingRoute)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 28)
        }
    }

    private var statusText: String {
        if vm.isFetchingRoute { return "Snapping to road…" }
        if vm.isLoopClosed { return "\(vm.rawWaypoints.count) points — loop closed" }
        if let direction = vm.currentPassDirection {
            return "\(vm.rawWaypoints.count) points — \(direction.capitalized)"
        }
        return "\(vm.rawWaypoints.count) points — tap roads to add"
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
                placedStops: [],
                isLoopClosed: vm.isLoopClosed
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Coordinate Precision")
                                    .font(.subheadline.bold())
                                if let direction = vm.currentPassDirection {
                                    Text(direction.capitalized)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.ember.opacity(0.12))
                                        .foregroundStyle(Color.ember)
                                        .clipShape(Capsule())
                                }
                            }
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
                placedStops: vm.placedStops,
                stopAnnotationMode: .flexible,
                isLoopClosed: vm.isLoopClosed,
                onMapTap: { coord in vm.addStop(at: coord) },
                onStopTap: { id in vm.removeStop(id: id) }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // This route uses the same road twice, so stop order can't be inferred from
                // position alone — say so, since marking out of order is what corrupts it.
                if vm.pathDoublesBack {
                    VStack(spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.ember)
                            Text("This route passes the same road twice. Mark stops in travel order, and check the list below matches the order the vehicle serves them.")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle(isOn: $vm.placeAnywhereAlongPath) {
                            Text("Place anywhere (ignore travel order)")
                                .font(.caption2)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                if let error = vm.stopPlacementError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.vermilion)
                        Text(error)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            vm.stopPlacementError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                // Instruction pill
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                    Text("Tap anywhere along the route to add a stop")
                        .font(.caption)
                    if let direction = vm.currentPassDirection {
                        Text("· \(direction.capitalized)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.ember)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)

                // Stop list — in path order, matches the order stops will be saved in.
                // Tap a stop's pin on the map, or the X here, to remove it.
                if !vm.placedStops.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.orderedPlacedStops) { stop in
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(Color.ember)
                                    TextField("Stop name", text: Binding(
                                        get: { stop.name },
                                        set: { vm.renameStop(id: stop.id, to: $0) }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                                    Button {
                                        vm.removeStop(id: stop.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
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

                    Button { vm.finishCurrentPass() } label: {
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
    @State private var showAppendConfirmation = false

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

                if let status = vm.lineIdStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isBlocking ? Color.vermilion : Color.slate)
                }
            }

            Section("Transport") {
                Picker("Mode", selection: $vm.selectedMode) {
                    ForEach([TransportMode.jeepney, .bus, .tricycle, .train], id: \.self) { m in
                        Text(m.rawValue.capitalized).tag(m)
                    }
                }
                Toggle("Air Conditioned", isOn: $vm.isAirConditioned)

                // A directional pass is one-way by definition, and the backend rejects the
                // other combination — so only offer the choice when it's actually a choice.
                if vm.hasDirectionalPass {
                    LabeledContent("Direction of travel") {
                        Text("One-way").foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("One-way route", isOn: $vm.isOneWay)
                        Text(vm.isOneWay
                             ? "Stops are served in the recorded direction only. Correct for most jeepney and bus routes."
                             : "The same stops serve both directions. Only correct when riders board at the same spot going either way.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                Button { vm.backToDefiningStopsFromMetadata() } label: {
                    Label("Back", systemImage: "chevron.left")
                }

                Button {
                    // A non-blocking lineIdStatus means this save would append to an
                    // existing route someone else created — confirm before doing that,
                    // rather than silently merging into it.
                    if vm.lineIdStatus?.isBlocking == false {
                        showAppendConfirmation = true
                    } else {
                        Task { await vm.generateAndSave() }
                    }
                } label: {
                    if vm.isSaving {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Saving…")
                        }
                    } else {
                        Label("Save & Add Route", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.licorice)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(vm.canSave ? Color.tangerine : Color.faint)
                .foregroundStyle(Color.licorice)
                .disabled(!vm.canSave || vm.isSaving)
                .confirmationDialog(
                    "Add to Existing Route?",
                    isPresented: $showAppendConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Add to Existing Route") {
                        Task { await vm.generateAndSave() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(vm.lineIdStatus?.message ?? "This will add the recorded direction to the existing route with this Line ID.")
                }
            }

            if let err = vm.errorMessage {
                Section {
                    Text(err).foregroundStyle(Color.vermilion).font(.caption)
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
                .foregroundStyle(Color.jade)

            VStack(spacing: 8) {
                Text("Route Added!")
                    .font(.title2.bold())
                Text(vm.routeDisplayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let result = vm.savedResult {
                    Text("\(result.stationsAdded) stops · \(result.edgesAdded) edges"
                         + (vm.completedPasses.count > 1 ? " · \(vm.completedPasses.count) directions" : ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("The route has been saved to the transit database.\nThe Explore tab will show it after reloading.")
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
