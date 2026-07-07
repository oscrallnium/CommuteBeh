//
//  TransportMode.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

// CommuteEngine.swift
// Commute Navigator — Metro Manila Multimodal A* Route Planner
//
// Architecture: MVVM + @Observable + Swift Concurrency
// Pathfinding: A* with binary min-heap, Haversine heuristic, O((E + V) log V)
//
// Key design decisions
// ─────────────────────
// • Graph is built once at init into [StationID: [Edge]] adjacency dict → O(1) neighbor lookup
// • Closed set is Set<StationID> → O(1) membership test
// • Open set is a binary MinHeap<AStarNode> → O(log n) push/pop (better than sorted array's O(n))
// • Payment & mode filtering happens at edge expansion, not at graph load (keeps graph generic)
// • Peak-hour multipliers are applied lazily during edge cost calculation
// • Fare calculation is a pure function; no side effects

import Foundation
import SwiftUI

// MARK: - Domain Types

typealias StationID = String

enum TransportMode: String, Codable, CaseIterable, Hashable {
    case train
    case bus
    case jeepney
    case tricycle
    case walk        // interchange transfers; always allowed
}

/// Maps to the accepted payment strings in the JSON data.
enum PaymentMethod: String, Codable, CaseIterable, Hashable {
    case cash       = "cash"
    case gcash      = "gcash"
    case maya       = "maya"
    case card       = "card"
    case beepCard   = "beep_card"

    var displayName: String {
        switch self {
        case .cash:     return "Cash"
        case .gcash:    return "GCash"
        case .maya:     return "Maya"
        case .card:     return "Card"
        case .beepCard: return "Beep Card"
        }
    }
}

// MARK: - Data Models (mirror the JSON schema)

struct Coordinates: Codable, Hashable {
    let lat: Double
    let lng: Double
}

/// Decoded from `transportModes` in the JSON.
/// Single source of truth for display name, map colour, icon, and routing hints.
struct TransportModeConfig: Codable {
    let id: String
    let displayName: String
    let pluralName: String
    let sfSymbol: String
    let colorHex: String
    let mapLineWidthPt: Double
    let mapLineDash: [Double]
    let mkDirectionsTransportType: String
    let isUserSelectable: Bool     // false for "walk" — never shown in mode picker
    let isAlwaysAllowed: Bool      // true for "walk" — bypasses mode filter in A*
    let lines: [String]
    let defaultAcceptedPayments: [String]
    let notes: String
}

/// Decoded from `paymentMethods` in the JSON.
struct PaymentMethodConfig: Codable {
    let id: String
    let displayName: String
    let sfSymbol: String
    let colorHex: String
    let isDefault: Bool
    let acceptedByModes: [String]
    let notes: String
}

struct Station: Codable, Identifiable, Hashable {
    let id: StationID
    let name: String
    let shortName: String
    let line: String
    let type: String            // "train" | "bus" | "jeepney" | "tricycle"
    let coordinates: Coordinates
    let isTerminal: Bool
    let isInterchange: Bool
    let interchangesWith: [StationID]?
    let amenities: [String]
    let operatingHours: OperatingHours

    struct OperatingHours: Codable, Hashable {
        let open: String
        let close: String
    }
}

struct TransitEdge: Codable, Identifiable {
    let id: String
    let from: StationID
    let to: StationID
    let mode: String            // raw string from JSON ("train" | "bus" | "jeepney" | "tricycle" | "walk")
    let line: String
    let travelTimeMinutes: Double
    let distanceKm: Double
    let baseFare: Double
    let farePerKm: Double
    let acceptedPayments: [String]
    let isAirConditioned: Bool
    let crowdFactor: Double     // 0.0–1.0; higher = more crowded → higher effective cost
    let reliability: Double     // 0.0–1.0; lower = less reliable → higher effective cost
    let bidirectional: Bool

    /// For lines with explicit directional edges (e.g. MRT-3 after the NB/SB split),
    /// this is "northbound" or "southbound". Nil for bidirectional or non-directional edges.
    /// Used by the UI to label the direction of travel on a leg.
    let direction: String?

    /// Ordered lat/lng coordinates that define the static visual shape of this edge on the map.
    /// Always starts with the `from` station coordinate and ends with the `to` station coordinate.
    /// Intermediate points follow the physical alignment of the route (rail track, road, etc.).
    /// These are fixed — they do not change with traffic or rerouting.
    let polylineCoordinates: [Coordinates]

    /// MKDirections transport type hint: "transit" | "walking" | "automobile"
    /// Used ONLY for fetching ETA from Apple Maps. The returned MKRoute.polyline is discarded.
    let mkDirectionsTransportType: String

    /// True when polylineCoordinates were captured directly from MKDirections and already follow roads.
    /// ExploreView skips its own road-snapping pass for these edges to avoid re-routing on
    /// a sparser set of waypoints that may produce a different path.
    let isRoadSnapped: Bool?

    var transportMode: TransportMode {
        TransportMode(rawValue: mode) ?? .walk
    }

    var acceptedPaymentSet: Set<String> {
        Set(acceptedPayments)
    }
}

struct PeakHourMultiplier: Codable {
    struct TimeRange: Codable {
        let start: String
        let close: String

        enum CodingKeys: String, CodingKey {
            case start
            case close = "end"  // "end" is a reserved keyword; remap
        }
    }
    let timeRange: TimeRange
    let travelTimeMultiplier: Double
    let modes: [String]
}

struct TransitGraph: Codable {
    struct PeakHours: Codable {
        let morningPeak: PeakHourMultiplier
        let eveningPeak: PeakHourMultiplier
        let trainPeak: PeakHourMultiplier
    }
    let version: String
    let stations: [Station]
    let edges: [TransitEdge]
    let peakHourMultipliers: PeakHours
    /// Keyed by mode id string (e.g. "train", "bus", "jeepney", "tricycle", "walk")
    let transportModes: [String: TransportModeConfig]
    /// Keyed by payment id string (e.g. "cash", "beep_card", "gcash", "maya", "card")
    let paymentMethods: [String: PaymentMethodConfig]
    /// Backend-controlled flag. When false, A* ignores station operating hours entirely.
    /// Defaults to true for backwards compatibility with cached graphs that lack this key.
    let enforceOperatingHours: Bool

    init(version: String, stations: [Station], edges: [TransitEdge],
         peakHourMultipliers: PeakHours, transportModes: [String: TransportModeConfig],
         paymentMethods: [String: PaymentMethodConfig], enforceOperatingHours: Bool = true) {
        self.version = version
        self.stations = stations
        self.edges = edges
        self.peakHourMultipliers = peakHourMultipliers
        self.transportModes = transportModes
        self.paymentMethods = paymentMethods
        self.enforceOperatingHours = enforceOperatingHours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Backend returns version as an Int (e.g. 1); local re-encoded files store it as a String.
        // Accept both so downloads and cached reads work without separate code paths.
        if let intV = try? c.decode(Int.self, forKey: .version) {
            version = String(intV)
        } else {
            version = try c.decode(String.self, forKey: .version)
        }
        stations             = try c.decode([Station].self,                       forKey: .stations)
        edges                = try c.decode([TransitEdge].self,                   forKey: .edges)
        peakHourMultipliers  = try c.decode(PeakHours.self,                       forKey: .peakHourMultipliers)
        transportModes       = try c.decode([String: TransportModeConfig].self,   forKey: .transportModes)
        paymentMethods       = try c.decode([String: PaymentMethodConfig].self,   forKey: .paymentMethods)
        enforceOperatingHours = try c.decodeIfPresent(Bool.self, forKey: .enforceOperatingHours) ?? true
    }
}

// MARK: - Route Request / Result

struct RouteRequest {
    let originID: StationID
    let destinationID: StationID
    let preferredPayments: Set<PaymentMethod>   // empty = accept any
    let allowedModes: Set<TransportMode>         // empty = allow all (except walk is always allowed)
    let departureTime: Date                      // used for peak-hour factor

    // Convenience: "now" defaults
    init(
        from originID: StationID,
        to destinationID: StationID,
        preferredPayments: Set<PaymentMethod> = [],
        allowedModes: Set<TransportMode> = [],
        departureTime: Date = .now
    ) {
        self.originID = originID
        self.destinationID = destinationID
        self.preferredPayments = preferredPayments
        self.allowedModes = allowedModes
        self.departureTime = departureTime
    }
}

// MARK: - Internal raw step (one per A* edge; never shown directly to the user)

/// One segment of the A* path — exactly one graph edge.
/// Used internally for polyline stitching and fare calculation.
/// Consolidated into RouteLeg before being surfaced to the UI.
struct RawStep {
    let fromStation: Station
    let toStation: Station
    let edge: TransitEdge
    let effectiveTravelMinutes: Double
    let estimatedArrival: Date
}

// MARK: - User-facing leg (one continuous ride on a single line/vehicle)

/// A RouteLeg represents one uninterrupted ride:
/// the passenger boards at fromStation, stays on the same vehicle/line,
/// and alights at toStation without any transfer in between.
///
/// For trains this means one boarding → one alighting regardless of how many
/// stations the train passes through.
struct RouteLeg: Identifiable {
    let id = UUID()

    /// Station where the passenger boards / starts walking.
    let fromStation: Station
    /// Station where the passenger alights / finishes walking.
    let toStation: Station

    /// Transport mode for this leg.
    let mode: TransportMode
    /// Line identifier (e.g. "MRT-3", "LRT-2", "INTERCHANGE").
    let line: String

    /// Travel direction for lines that have explicit directional edges.
    /// "northbound" | "southbound" | nil for undirected lines.
    let direction: String?

    /// All stations on this leg in order, inclusive of from and to.
    /// Count > 2 means intermediate stops the vehicle passes through.
    let stops: [Station]

    /// Combined effective travel time across all merged raw steps (minutes).
    let effectiveTravelMinutes: Double
    /// Combined fare for this leg (single boarding, distance-summed).
    let fare: Double
    /// Combined distance across all merged raw steps (km).
    let distanceKm: Double

    /// Number of stations traversed, not counting the boarding station itself.
    var stopCount: Int { max(0, stops.count - 1) }

    /// Merged polyline coordinates — all raw step polylines concatenated,
    /// with shared junction points de-duplicated.
    let polylineCoordinates: [Coordinates]

    /// Wall-clock estimated arrival at toStation.
    let estimatedArrival: Date

    /// Human-readable instruction for this leg.
    let instruction: String

    /// The raw A* steps merged into this leg.
    /// Retained for per-segment MKDirections ETA calls and AR navigation.
    let rawSteps: [RawStep]
}

struct RouteResult {
    /// User-facing legs — one entry per continuous ride, no spurious reboarding.
    let legs: [RouteLeg]
    let totalTimeMinutes: Double
    let totalFare: Double
    let totalDistanceKm: Double
    /// Number of actual vehicle changes (walk legs excluded).
    let transfers: Int
    /// Ordered list of non-walk modes used in the route.
    let modes: [TransportMode]

    var isEmpty: Bool { legs.isEmpty }
}

// MARK: - A* Internals

/// A node in the A* open set.
private struct AStarNode: Comparable {
    let stationID: StationID
    let gCost: Double       // actual cost from origin (minutes)
    let hCost: Double       // heuristic estimate to destination (minutes)
    let fCost: Double       // g + h
    let parent: StationID?
    let edgeFromParent: TransitEdge?

    init(stationID: StationID, gCost: Double, hCost: Double,
         parent: StationID? = nil, edgeFromParent: TransitEdge? = nil) {
        self.stationID = stationID
        self.gCost = gCost
        self.hCost = hCost
        self.fCost = gCost + hCost
        self.parent = parent
        self.edgeFromParent = edgeFromParent
    }

    static func < (lhs: AStarNode, rhs: AStarNode) -> Bool {
        lhs.fCost < rhs.fCost
    }

    static func == (lhs: AStarNode, rhs: AStarNode) -> Bool {
        lhs.fCost == rhs.fCost
    }
}

/// Binary min-heap — O(log n) push and popMin.
/// Using this instead of a sorted array because sorted insertion is O(n).
private struct MinHeap<T: Comparable> {
    private var elements: [T] = []

    var isEmpty: Bool { elements.isEmpty }

    mutating func push(_ value: T) {
        elements.append(value)
        siftUp(from: elements.count - 1)
    }

    mutating func popMin() -> T? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let min = elements[0]
        elements[0] = elements.removeLast()
        siftDown(from: 0)
        return min
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if elements[child] < elements[parent] {
                elements.swapAt(child, parent)
                child = parent
            } else { break }
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        let count = elements.count
        while true {
            let left = 2 * parent + 1
            let right = 2 * parent + 2
            var candidate = parent
            if left < count && elements[left] < elements[candidate] { candidate = left }
            if right < count && elements[right] < elements[candidate] { candidate = right }
            if candidate == parent { break }
            elements.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

// MARK: - Transit Graph Engine (actor for thread safety)

actor TransitGraphEngine {

    // Adjacency list: stationID → outgoing edges
    // Built once; reused across all route calculations.
    private let adjacency: [StationID: [TransitEdge]]
    private let stationMap: [StationID: Station]
    private let peakHours: TransitGraph.PeakHours

    /// Decoded from JSON — single source of truth for mode display & routing properties.
    let transportModes: [String: TransportModeConfig]
    /// Decoded from JSON — single source of truth for payment display properties.
    let paymentMethods: [String: PaymentMethodConfig]

    /// Mode IDs where `isAlwaysAllowed = true` (e.g. "walk").
    /// Derived once at init from JSON so A* never hard-codes mode strings.
    private let alwaysAllowedModes: Set<String>
    /// When false, all station operating-hours checks are skipped entirely.
    private let enforceOperatingHours: Bool

    // MARK: Init

    /// Loads the bundled JSON graph and builds O(1) adjacency structures.
    /// Time: O(E) to build adjacency. Space: O(V + E).
    init(graph: TransitGraph) {
        var adj: [StationID: [TransitEdge]] = [:]
        var stMap: [StationID: Station] = [:]

        for station in graph.stations {
            stMap[station.id] = station
            adj[station.id] = []
        }

        for edge in graph.edges {
            adj[edge.from, default: []].append(edge)
            if edge.bidirectional {
                // Create synthetic reverse edge
                // Reverse direction label: flip if present, otherwise nil.
                let reverseDirection: String?
                switch edge.direction {
                case "northbound": reverseDirection = "southbound"
                case "southbound": reverseDirection = "northbound"
                default:           reverseDirection = nil
                }
                let reverse = TransitEdge(
                    id: edge.id + "_rev",
                    from: edge.to,
                    to: edge.from,
                    mode: edge.mode,
                    line: edge.line,
                    travelTimeMinutes: edge.travelTimeMinutes,
                    distanceKm: edge.distanceKm,
                    baseFare: edge.baseFare,
                    farePerKm: edge.farePerKm,
                    acceptedPayments: edge.acceptedPayments,
                    isAirConditioned: edge.isAirConditioned,
                    crowdFactor: edge.crowdFactor,
                    reliability: edge.reliability,
                    bidirectional: false,
                    direction: reverseDirection,
                    polylineCoordinates: edge.polylineCoordinates.reversed(),
                    mkDirectionsTransportType: edge.mkDirectionsTransportType,
                    isRoadSnapped: edge.isRoadSnapped
                )
                adj[edge.to, default: []].append(reverse)
            }
        }

        adjacency = adj
        stationMap = stMap
        peakHours = graph.peakHourMultipliers
        transportModes = graph.transportModes
        paymentMethods = graph.paymentMethods

        // Derive the always-allowed set from JSON data — no hardcoded mode strings.
        alwaysAllowedModes = Set(
            graph.transportModes.values
                .filter(\.isAlwaysAllowed)
                .map(\.id)
        )
        enforceOperatingHours = graph.enforceOperatingHours
    }

    // MARK: - Public API

    enum RouteError: Error {
        case stationsClosed(closeTime: String)
        case noPath
    }

    func findRoute(_ request: RouteRequest) -> Result<RouteResult, RouteError> {
        guard stationMap[request.originID] != nil,
              stationMap[request.destinationID] != nil else {
            return .failure(.noPath)
        }

        guard request.originID != request.destinationID else {
            return .success(RouteResult(legs: [], totalTimeMinutes: 0, totalFare: 0,
                                        totalDistanceKm: 0, transfers: 0, modes: []))
        }

        // Pre-flight: if operating hours are enforced and the origin or destination
        // station is outside its window at the requested departure time, report that
        // specifically so the UI can show "Stations closed" instead of a generic error.
        if enforceOperatingHours {
            let depHour   = Calendar.current.component(.hour,   from: request.departureTime)
            let depMinute = Calendar.current.component(.minute, from: request.departureTime)
            let departureMinutes = depHour * 60 + depMinute

            for stationID in [request.originID, request.destinationID] {
                guard let station = stationMap[stationID] else { continue }
                if !stationOpen(station, arrivalMinutes: departureMinutes, isAlwaysAllowed: false) {
                    return .failure(.stationsClosed(closeTime: station.operatingHours.close))
                }
            }
        }

        if let result = astar(request: request) {
            return .success(result)
        }
        return .failure(.noPath)
    }

    // MARK: Station lookup helpers (used by ViewModel)

    func station(id: StationID) -> Station? {
        stationMap[id]
    }

    func allStations() -> [Station] {
        Array(stationMap.values).sorted { $0.name < $1.name }
    }

    func stations(matching query: String) -> [Station] {
        let q = query.lowercased()
        return allStations().filter {
            $0.name.lowercased().contains(q) || $0.shortName.lowercased().contains(q)
        }
    }

    // MARK: Mode & payment config helpers (used by ViewModel / UI)

    /// Ordered list of modes the user can toggle in the filter UI.
    func selectableModes() -> [TransportModeConfig] {
        transportModes.values
            .filter(\.isUserSelectable)
            .sorted { $0.displayName < $1.displayName }
    }

    /// Ordered list of payment methods for the payment picker UI.
    func selectablePayments() -> [PaymentMethodConfig] {
        paymentMethods.values
            .sorted { $0.displayName < $1.displayName }
    }

    func modeConfig(for modeID: String) -> TransportModeConfig? {
        transportModes[modeID]
    }

    func paymentConfig(for paymentID: String) -> PaymentMethodConfig? {
        paymentMethods[paymentID]
    }

    // MARK: - A* Core
    // Time complexity: O((V + E) log V) with binary heap
    // V = number of stations, E = number of edges (including reversed)

    // MARK: - Operating Hours Helper
    //
    // Converts an "HH:mm" string to minutes-since-midnight.
    // Stations that close at or after 00:00 the next day are treated as closing
    // at 1440 (midnight) for safety — none in the current dataset cross midnight.
    //
    // Rule applied at edge expansion:
    //   arrivalMinutes = departureMinutesSinceMidnight + gCost(neighbor)
    //   isOpen = arrivalMinutes < closeMinutes
    //
    // Walk/interchange edges bypass this check entirely — the concourse is always
    // passable even if the paid platform has closed.

    private func minutesSinceMidnight(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    /// Returns true if a traveller arriving `arrivalMinutes` minutes after midnight
    /// can still use `station` (i.e. the station is within its operating window).
    /// Walk/interchange edges bypass this — returns true unconditionally for them.
    private func stationOpen(_ station: Station, arrivalMinutes: Int, isAlwaysAllowed: Bool) -> Bool {
        guard !isAlwaysAllowed else { return true }
        let open  = minutesSinceMidnight(station.operatingHours.open)
        let close = minutesSinceMidnight(station.operatingHours.close)
        // Overnight service (e.g. close=00:00 < open=05:00): always passable.
        if close <= open { return true }
        return arrivalMinutes >= open && arrivalMinutes < close
    }

    private func astar(request: RouteRequest) -> RouteResult? {
        let destination = request.destinationID
        let destCoords = stationMap[destination]!.coordinates

        // Wall-clock departure expressed as minutes since midnight.
        // Used to compute estimated arrival time at each neighbour station.
        let calendar = Calendar.current
        let depHour   = calendar.component(.hour,   from: request.departureTime)
        let depMinute = calendar.component(.minute, from: request.departureTime)
        let departureMinutes = depHour * 60 + depMinute   // e.g. 22:50 → 1370

        // gScore: best known actual cost to reach each station
        var gScore: [StationID: Double] = [request.originID: 0]

        // cameFrom: reconstruct path — parent station + edge that got us here
        var cameFrom: [StationID: (parent: StationID, edge: TransitEdge)] = [:]

        // Closed set: stations we've already settled
        var closed: Set<StationID> = []

        // Open set: binary min-heap keyed on fCost
        var openHeap = MinHeap<AStarNode>()
        let originH = heuristic(from: stationMap[request.originID]!.coordinates, to: destCoords)
        openHeap.push(AStarNode(stationID: request.originID, gCost: 0, hCost: originH))

        while let current = openHeap.popMin() {
            let currentID = current.stationID

            // We may have stale (higher-cost) entries in the heap — skip them.
            // This is the standard "lazy deletion" pattern for A* with a simple heap.
            if let bestG = gScore[currentID], current.gCost > bestG { continue }
            if closed.contains(currentID) { continue }
            closed.insert(currentID)

            if currentID == destination {
                return buildResult(
                    destination: destination,
                    cameFrom: cameFrom,
                    gScore: gScore,
                    stationMap: stationMap,
                    departureTime: request.departureTime
                )
            }

            let neighbors = adjacency[currentID] ?? []

            for edge in neighbors {
                let neighbor = edge.to
                guard !closed.contains(neighbor) else { continue }

                // ── Payment filter ──────────────────────────────────────────
                // Modes marked isAlwaysAllowed in the JSON (e.g. walk/interchange)
                // bypass both the payment filter and the mode filter entirely.
                let isAlwaysAllowed = alwaysAllowedModes.contains(edge.mode)
                if !isAlwaysAllowed {
                    if !request.preferredPayments.isEmpty {
                        let edgePayments = edge.acceptedPaymentSet
                        let userPayments = Set(request.preferredPayments.map { $0.rawValue })
                        guard !edgePayments.isDisjoint(with: userPayments) else { continue }
                    }

                    // ── Mode filter ─────────────────────────────────────────
                    if !request.allowedModes.isEmpty {
                        guard let mode = TransportMode(rawValue: edge.mode),
                              request.allowedModes.contains(mode) else { continue }
                    }
                }

                // ── Effective cost calculation ──────────────────────────────
                let rawMinutes = edge.travelTimeMinutes
                let peakMultiplier = peakMultiplier(for: edge, at: request.departureTime)

                // Cost function weights:
                //   • time (primary)
                //   • unreliability penalty: add up to 20% extra minutes
                //   • crowd penalty: add up to 10% extra minutes
                // All in "effective minutes" units → consistent A* heuristic
                let reliabilityPenalty = rawMinutes * (1.0 - edge.reliability) * 0.2
                let crowdPenalty       = rawMinutes * edge.crowdFactor * 0.1
                let effectiveMinutes   = (rawMinutes * peakMultiplier) + reliabilityPenalty + crowdPenalty

                let tentativeG = (gScore[currentID] ?? .infinity) + effectiveMinutes

                // ── Operating-hours filter ──────────────────────────────────
                // Skipped entirely when enforceOperatingHours is false (admin override).
                if enforceOperatingHours, let neighborStation = stationMap[neighbor] {
                    let arrivalMinutes = departureMinutes + Int(tentativeG)
                    guard stationOpen(neighborStation, arrivalMinutes: arrivalMinutes, isAlwaysAllowed: isAlwaysAllowed) else {
                        continue   // station closed at estimated arrival — skip this edge
                    }
                }

                if tentativeG < (gScore[neighbor] ?? .infinity),
                   let neighborCoords = stationMap[neighbor]?.coordinates {
                    gScore[neighbor] = tentativeG
                    cameFrom[neighbor] = (parent: currentID, edge: edge)
                    let h = heuristic(from: neighborCoords, to: destCoords)
                    openHeap.push(AStarNode(
                        stationID: neighbor,
                        gCost: tentativeG,
                        hCost: h,
                        parent: currentID,
                        edgeFromParent: edge
                    ))
                }
            }
        }

        return nil  // no route found
    }

    // MARK: - Heuristic
    // Haversine distance converted to estimated travel minutes.
    // Assumes 30 km/h average speed → always admissible (never overestimates real transit time).

    private func heuristic(from: Coordinates, to: Coordinates) -> Double {
        let distanceKm = haversine(from: from, to: to)
        let averageSpeedKmPerMin = 30.0 / 60.0  // 30 km/h in km/min
        return distanceKm / averageSpeedKmPerMin
    }

    private func haversine(from: Coordinates, to: Coordinates) -> Double {
        let R = 6371.0  // Earth radius in km
        let dLat = (to.lat - from.lat).toRadians
        let dLng = (to.lng - from.lng).toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(from.lat.toRadians) * cos(to.lat.toRadians)
            * sin(dLng / 2) * sin(dLng / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Peak Hour Multiplier

    private func peakMultiplier(for edge: TransitEdge, at date: Date) -> Double {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let totalMinutes = hour * 60 + minute

        func inRange(_ peak: PeakHourMultiplier) -> Bool {
            let parts = { (s: String) -> Int in
                let p = s.split(separator: ":").compactMap { Int($0) }
                return (p.first ?? 0) * 60 + (p.last ?? 0)
            }
            let start = parts(peak.timeRange.start)
            let end   = parts(peak.timeRange.close)
            return totalMinutes >= start && totalMinutes <= end
        }

        var multiplier = 1.0

        if peak(peakHours.morningPeak, applies: edge.mode, in: &multiplier, when: inRange(peakHours.morningPeak)) {}
        if peak(peakHours.eveningPeak, applies: edge.mode, in: &multiplier, when: inRange(peakHours.eveningPeak)) {}
        if peak(peakHours.trainPeak,   applies: edge.mode, in: &multiplier, when: inRange(peakHours.trainPeak))   {}

        return multiplier
    }

    @discardableResult
    private func peak(_ p: PeakHourMultiplier, applies mode: String, in multiplier: inout Double, when condition: Bool) -> Bool {
        guard condition && p.modes.contains(mode) else { return false }
        multiplier = max(multiplier, p.travelTimeMultiplier)
        return true
    }

    // MARK: - Path Reconstruction

    private func buildResult(
        destination: StationID,
        cameFrom: [StationID: (parent: StationID, edge: TransitEdge)],
        gScore: [StationID: Double],
        stationMap: [StationID: Station],
        departureTime: Date
    ) -> RouteResult {
        // ── Step 1: walk backwards from destination to rebuild A* path ────────
        var path: [(stationID: StationID, edge: TransitEdge?)] = [(destination, nil)]
        var current = destination
        while let record = cameFrom[current] {
            path.append((record.parent, record.edge))
            current = record.parent
        }
        path.reverse()  // origin → destination

        // ── Step 2: build flat RawSteps (one per A* edge) ────────────────────
        var rawSteps: [RawStep] = []

        for i in 0..<path.count - 1 {
            let fromID = path[i].stationID
            let toID   = path[i + 1].stationID
            guard let edge    = path[i + 1].edge,
                  let fromSt  = stationMap[fromID],
                  let toSt    = stationMap[toID] else { continue }

            let effectiveTime    = gScore[toID]! - (gScore[fromID] ?? 0)
            let cumulativeMinutes = gScore[toID] ?? 0
            let estimatedArrival  = departureTime.addingTimeInterval(cumulativeMinutes * 60)

            rawSteps.append(RawStep(
                fromStation: fromSt,
                toStation: toSt,
                edge: edge,
                effectiveTravelMinutes: effectiveTime,
                estimatedArrival: estimatedArrival
            ))
        }

        // ── Step 3: consolidate into user-facing RouteLeg list ───────────────
        let legs = consolidateLegs(rawSteps, departureTime: departureTime)

        // ── Step 4: aggregate totals ─────────────────────────────────────────
        let totalTime = legs.reduce(0) { $0 + $1.effectiveTravelMinutes }
        let totalFare = legs.reduce(0) { $0 + $1.fare }
        let totalDist = legs.reduce(0) { $0 + $1.distanceKm }

        var modesUsed: [TransportMode] = []
        for leg in legs where leg.mode != .walk {
            if modesUsed.last != leg.mode { modesUsed.append(leg.mode) }
        }

        let transfers = countTransfers(legs: legs)

        return RouteResult(
            legs: legs,
            totalTimeMinutes: totalTime,
            totalFare: totalFare,
            totalDistanceKm: totalDist,
            transfers: transfers,
            modes: modesUsed
        )
    }

    // MARK: - Leg Consolidation
    //
    // Merges consecutive RawSteps that share the same line into a single RouteLeg.
    //
    // Merge rule:
    //   steps[i] and steps[i+1] belong to the same leg when:
    //     • edge.line  is identical  (e.g. both "MRT-3")
    //     • edge.mode  is identical  (e.g. both "train")
    //     • NOT a walk/interchange line (each walk is always its own leg)
    //   These conditions together mean the passenger stays on the same vehicle.
    //
    // Polyline stitching: concatenate polylineCoordinates arrays, dropping the
    // first point of each subsequent step (it duplicates the last point of the
    // previous step — the shared intermediate station).

    private func consolidateLegs(_ rawSteps: [RawStep], departureTime: Date) -> [RouteLeg] {
        guard !rawSteps.isEmpty else { return [] }

        var legs: [RouteLeg] = []
        var buffer: [RawStep] = [rawSteps[0]]

        func canMerge(_ a: RawStep, _ b: RawStep) -> Bool {
            let aLine = a.edge.line
            let bLine = b.edge.line
            // Walk/interchange legs are never merged with anything
            if aLine == "INTERCHANGE" || bLine == "INTERCHANGE" { return false }
            return aLine == bLine && a.edge.mode == b.edge.mode
        }

        func flush(_ buffer: [RawStep]) -> RouteLeg {
            let first = buffer.first!
            let last  = buffer.last!

            // Stops: boarding station + every alighting station in the buffer
            var stops: [Station] = [first.fromStation]
            for step in buffer { stops.append(step.toStation) }

            // Polyline: stitch all coordinate arrays, de-duplicating junction points
            var polyline: [Coordinates] = first.edge.polylineCoordinates
            for step in buffer.dropFirst() {
                // The first coordinate of the next segment == last coordinate of
                // the previous one (the shared intermediate station). Drop it.
                let coords = step.edge.polylineCoordinates.dropFirst()
                polyline.append(contentsOf: coords)
            }

            let totalTime = buffer.reduce(0) { $0 + $1.effectiveTravelMinutes }
            let totalDist = buffer.reduce(0) { $0 + $1.edge.distanceKm }
            let totalFare = computeLegFare(buffer)

            let mode = first.edge.transportMode
            let line = first.edge.line
            let legDirection = first.edge.direction

            let instruction = buildLegInstruction(
                mode: mode,
                line: line,
                direction: legDirection,
                from: first.fromStation,
                to: last.toStation,
                stopCount: stops.count - 1
            )

            // Direction: all merged steps must agree on direction (they will —
            // same-line consolidation guarantees same direction label).
            return RouteLeg(
                fromStation: first.fromStation,
                toStation: last.toStation,
                mode: mode,
                line: line,
                direction: legDirection,
                stops: stops,
                effectiveTravelMinutes: totalTime,
                fare: totalFare,
                distanceKm: totalDist,
                polylineCoordinates: polyline,
                estimatedArrival: last.estimatedArrival,
                instruction: instruction,
                rawSteps: buffer
            )
        }

        for step in rawSteps.dropFirst() {
            if canMerge(buffer.last!, step) {
                buffer.append(step)
            } else {
                legs.append(flush(buffer))
                buffer = [step]
            }
        }
        legs.append(flush(buffer))

        return legs
    }

    // MARK: - Fare Computation (leg-level)
    //
    // For a single-boarding leg the fare is computed once on the whole leg,
    // not summed per edge. This gives correct results for distance-bracketed
    // lines (MRT-3, LRT-1, LRT-2) where the passenger pays one fare at the
    // gate regardless of how many stations are traversed.

    private func computeLegFare(_ steps: [RawStep]) -> Double {
        guard let first = steps.first else { return 0 }
        let mode = first.edge.transportMode
        guard mode != .walk else { return 0 }

        // Sum the total distance across all merged segments
        let totalDist = steps.reduce(0.0) { $0 + $1.edge.distanceKm }

        // If any edge in the leg charges per-km, apply it to the full leg distance.
        // Otherwise use the flat base fare from the first edge (all edges on the
        // same line share the same fare structure).
        let hasPerKm = steps.contains { $0.edge.farePerKm > 0 }
        if hasPerKm {
            return first.edge.baseFare + totalDist * first.edge.farePerKm
        }
        return first.edge.baseFare
    }

    // MARK: - Leg Instruction Builder

    private func buildLegInstruction(
        mode: TransportMode,
        line: String,
        direction: String?,
        from: Station,
        to: Station,
        stopCount: Int
    ) -> String {
        let stopsLabel = stopCount == 1 ? "1 stop" : "\(stopCount) stops"
        switch mode {
        case .train:
            let dirLabel = direction.map { " (\($0.capitalized))" } ?? ""
            return "Board \(line)\(dirLabel) at \(from.shortName), ride to \(to.shortName) (\(stopsLabel))"
        case .bus:
            return "Take \(line) bus from \(from.shortName) to \(to.shortName) (\(stopsLabel))"
        case .jeepney:
            return "Ride jeepney (\(line)) from \(from.shortName) to \(to.shortName)"
        case .tricycle:
            return "Take tricycle from \(from.shortName) to \(to.shortName)"
        case .walk:
            if from.isInterchange || to.isInterchange {
                return "Transfer: Walk from \(from.shortName) to \(to.shortName)"
            }
            return "Walk from \(from.shortName) to \(to.shortName)"
        }
    }

    private func countTransfers(legs: [RouteLeg]) -> Int {
        // A transfer is a change from one non-walk line to another non-walk line.
        // Walk/interchange legs between two transit legs are not counted as transfers
        // themselves — they are the mechanism of a transfer, not the transfer event.
        var transfers = 0
        var previousNonWalkLine = ""
        for leg in legs {
            guard leg.line != "INTERCHANGE" && leg.mode != .walk else { continue }
            if !previousNonWalkLine.isEmpty && leg.line != previousNonWalkLine {
                transfers += 1
            }
            previousNonWalkLine = leg.line
        }
        return transfers
    }
}

// MARK: - Graph Loader

enum GraphLoadError: Error {
    case fileNotFound
    case decodingFailed(Error)
}

struct GraphLoader {
    /// Loads the graph from the Documents cache only. Returns `.failure(.fileNotFound)`
    /// if no cached file exists — callers should call `ensureLoaded()` instead when
    /// they want an automatic network fetch on first launch.
    static func load(from fileName: String = "transit_graph_v3") -> Result<TransitGraph, GraphLoadError> {
        guard let url = documentsURL(for: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileNotFound)
        }
        do {
            let data = try Data(contentsOf: url)
            let graph = try JSONDecoder().decode(TransitGraph.self, from: data)
            return .success(graph)
        } catch {
            return .failure(.decodingFailed(error))
        }
    }

    /// Like `load()` but fetches the graph from the backend when no valid local copy
    /// exists. Handles both missing files and stale/corrupt caches by re-downloading.
    static func ensureLoaded(from fileName: String = "transit_graph_v3") async -> Result<TransitGraph, GraphLoadError> {
        switch load(from: fileName) {
        case .success(let g): return .success(g)
        case .failure:
            // fileNotFound: first launch. decodingFailed: corrupt or pre-fix cache.
            // Either way, fetch a fresh copy from the backend.
            guard let data = try? await GraphService.shared.fetchGraph(),
                  let url = documentsURL(for: fileName) else {
                return .failure(.fileNotFound)
            }
            try? data.write(to: url)
            return load(from: fileName)
        }
    }

    static func documentsURL(for fileName: String = "transit_graph_v3") -> URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("\(fileName).json")
    }
}

// MARK: - Station Cache
// Lightweight [Station] cache persisted to Documents.
// Loaded synchronously on ViewModel init so search works before the full
// routing engine finishes its async setup.

struct StationCache {
    private static let fileName = "stations_cache"

    static func save(_ stations: [Station]) {
        guard let url = GraphLoader.documentsURL(for: fileName),
              let data = try? JSONEncoder().encode(stations) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> [Station] {
        guard let url = GraphLoader.documentsURL(for: fileName),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stations = try? JSONDecoder().decode([Station].self, from: data) else {
            return []
        }
        return stations.sorted { $0.name < $1.name }
    }
}

// MARK: - ViewModel

@Observable
final class CommuteViewModel {

    // MARK: State
    var originID: StationID = ""
    var destinationID: StationID = ""
    var selectedPayments: Set<PaymentMethod> = [.cash]
    var selectedModes: Set<TransportMode> = Set(TransportMode.allCases.filter { $0 != .walk })
    var departureTime: Date = .now
    var useScheduledTime: Bool = false

    var routeResult: RouteResult?
    var isLoading: Bool = false
    var errorMessage: String?
    var allStations: [Station] = []
    var searchQuery: String = ""
    var filteredStations: [Station] = []

    /// Populated from JSON — drives the mode filter picker UI.
    var availableModes: [TransportModeConfig] = []
    /// Populated from JSON — drives the payment method picker UI.
    var availablePayments: [PaymentMethodConfig] = []

    private var engine: TransitGraphEngine?

    // MARK: Init

    init() {
        // Populate stations immediately from disk cache so search works before
        // the async engine finishes loading (or on subsequent launches).
        self.allStations = StationCache.load()
        Task { await setupEngine() }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("TransitDataDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.setupEngine() }
        }
    }

    @MainActor
    private func setupEngine() async {
        switch await GraphLoader.ensureLoaded() {
        case .success(let graph):
            let eng = TransitGraphEngine(graph: graph)
            self.engine = eng
            let stations = await eng.allStations()
            self.allStations = stations
            self.availableModes = await eng.selectableModes()
            self.availablePayments = await eng.selectablePayments()
            StationCache.save(stations)
            let loadedVersion = graph.version
            Task.detached(priority: .background) {
                await GraphService.shared.syncIfNeeded(loadedVersion: loadedVersion)
            }
        case .failure:
            self.errorMessage = "Couldn't load transit data. Check your connection and try again."
        }
    }

    // MARK: Route Calculation

    @MainActor
    func calculateRoute() async {
        guard let engine else {
            errorMessage = "Transit engine not ready."
            return
        }
        guard !originID.isEmpty, !destinationID.isEmpty else {
            errorMessage = "Please select both origin and destination."
            return
        }

        isLoading = true
        errorMessage = nil
        routeResult = nil

        let request = RouteRequest(
            from: originID,
            to: destinationID,
            preferredPayments: selectedPayments,
            allowedModes: selectedModes,
            departureTime: useScheduledTime ? departureTime : .now
        )

        // Push work off main thread; engine is an actor so this is safe
        let result = await Task.detached(priority: .userInitiated) {
            await engine.findRoute(request)
        }.value

        isLoading = false

        switch result {
        case .success(let route):
            routeResult = route
        case .failure(.stationsClosed(let closeTime)):
            errorMessage = "Stations are closed at this time. MRT/LRT service ends at \(formattedTime(closeTime))."
        case .failure(.noPath):
            errorMessage = "No route found between these stations."
        }
    }

    // MARK: Helpers

    private func formattedTime(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return hhmm }
        let hour = parts[0]
        let minute = parts[1]
        let period = hour < 12 ? "AM" : "PM"
        let h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return minute == 0 ? "\(h):00 \(period)" : "\(h):\(String(format: "%02d", minute)) \(period)"
    }

    // MARK: Station Search

    @MainActor
    func searchStations(query: String) async {
        guard let engine else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            filteredStations = allStations
            return
        }
        filteredStations = await engine.stations(matching: q)
    }

    // MARK: Convenience

    var effectiveDepartureTime: Date {
        useScheduledTime ? departureTime : .now
    }

    var canCalculate: Bool {
        !originID.isEmpty && !destinationID.isEmpty && engine != nil
    }
}

// MARK: - Helpers

private extension Double {
    var toRadians: Double { self * .pi / 180 }
}
