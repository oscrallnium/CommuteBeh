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

import CoreLocation
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

/// Decoded from `lines` in the JSON — the human-readable name for a line key like
/// "UPLB_KANAN" or "EDSA_BUS". Train lines (MRT-3, LRT-1, LRT-2) read fine as their raw
/// key and are included here too, so callers never need a mode-specific exception.
struct LineConfig: Codable {
    let id: String
    let displayName: String
    /// Present on every line seeded server-side; optional only so a hand-written test
    /// fixture that omits it still decodes.
    let mode: String?
}

/// A stop, or one of the two synthetic nodes the engine injects for a pinned coordinate
/// (see `isPinnedLocation`).
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

    /// Street-level doors, when any have been surveyed for this station.
    ///
    /// Optional and absent by default: the server omits the key entirely for a station
    /// with no doors, and the bundled `transit_graph_v3.json` predates the field. Every
    /// reader must therefore treat "no access points" as normal and fall back to
    /// `coordinates` — see `accessPoint(kind:direction:nearestTo:)`.
    let accessPoints: [StationAccessPoint]?

    struct OperatingHours: Codable, Hashable {
        let open: String
        let close: String
    }

    /// True for the synthetic `__ORIGIN__` / `__DEST__` nodes injected when routing from or
    /// to a raw coordinate. Unlike a real stop — which sits on the road its vehicles use —
    /// this is wherever the user's pin, GPS fix, or geocoded address landed: inside a mall,
    /// in the middle of a campus, behind a wall. Geometry must not be forced to meet it.
    var isPinnedLocation: Bool {
        id == RouteRequest.virtualOriginID || id == RouteRequest.virtualDestID
    }

    /// The door a passenger should use, or `coordinates` when none is recorded.
    ///
    /// Mirrors `StationAccessPoint.serving` on the server — keep the two in step. A door
    /// with no `direction` serves every direction, and when `direction` is `nil` here
    /// (an LRT leg, or any line without directional edges) *every* door is a candidate:
    /// filtering to the undirected ones would make a station whose doors are all
    /// direction-tagged report none at all, on exactly the legs that can never supply a
    /// direction.
    ///
    /// `nearestTo` breaks the tie. With several doors open to the passenger the right one
    /// is the one closest to where they are coming from or going to, which is also what
    /// makes this correct without knowing anything about the station's internal layout.
    func accessPoint(kind: StationAccessPoint.Kind,
                     direction: String?,
                     nearestTo other: Coordinates) -> Coordinates {
        guard let accessPoints, !accessPoints.isEmpty else { return coordinates }

        let candidates = accessPoints.filter { point in
            let kindMatches = point.kind == .both || point.kind == kind
            let directionMatches = point.direction == nil
                || direction == nil
                || point.direction == direction
            return kindMatches && directionMatches
        }

        // Squared-degree distance is enough to rank candidates a few hundred metres
        // apart; the longitude term is scaled by cos(lat) so the comparison is not
        // stretched east–west. No need for a full Haversine to pick a minimum.
        let scale = cos(other.lat * .pi / 180)
        return candidates.min { a, b in
            func d(_ c: Coordinates) -> Double {
                let dLat = c.lat - other.lat
                let dLng = (c.lng - other.lng) * scale
                return dLat * dLat + dLng * dLng
            }
            return d(a.coordinates) < d(b.coordinates)
        }?.coordinates ?? coordinates
    }
}

/// A street-level door into a station: an entrance, an exit, or both.
///
/// A station row carries one coordinate — the centroid of the structure — and for rail
/// that point sits on a viaduct or inside a building, not on any pedestrian way. Walks
/// measured from it get snapped by MKDirections to whatever footpath happens to be
/// nearest, which is why the MRT-3 Taft ⇄ LRT-1 EDSA transfer is routed between two
/// arbitrary points rather than between the doors the footbridge actually joins.
struct StationAccessPoint: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: Kind
    /// `"northbound"` / `"southbound"`, or `nil` when the door serves every direction —
    /// which is the common case. Only MRT-3 has directional edges at all.
    let direction: String?
    let coordinates: Coordinates

    /// Decoded leniently: an unrecognised value from a newer server becomes `.both`
    /// rather than failing the whole graph decode over one station's door.
    enum Kind: String, Codable, Hashable {
        case entrance, exit, both

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .both
        }
    }

    // Immutable setters — the type is all `let`, and the admin editor needs to change one
    // field at a time without restating the rest.

    func settingName(_ name: String) -> StationAccessPoint {
        StationAccessPoint(id: id, name: name, kind: kind,
                           direction: direction, coordinates: coordinates)
    }

    func settingKind(_ kind: Kind) -> StationAccessPoint {
        StationAccessPoint(id: id, name: name, kind: kind,
                           direction: direction, coordinates: coordinates)
    }

    func settingDirection(_ direction: String?) -> StationAccessPoint {
        StationAccessPoint(id: id, name: name, kind: kind,
                           direction: direction, coordinates: coordinates)
    }

    func settingCoordinates(_ coordinates: Coordinates) -> StationAccessPoint {
        StationAccessPoint(id: id, name: name, kind: kind,
                           direction: direction, coordinates: coordinates)
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
    /// Keyed by line id string (e.g. "UPLB_KANAN", "EDSA_BUS", "MRT-3"). Empty for a
    /// cached graph downloaded before this field existed — see `init(from:)` — so a
    /// missing entry always falls back to the raw line id rather than crashing.
    let lines: [String: LineConfig]
    /// Backend-controlled flag. When false, A* ignores station operating hours entirely.
    /// Defaults to true for backwards compatibility with cached graphs that lack this key.
    let enforceOperatingHours: Bool

    init(version: String, stations: [Station], edges: [TransitEdge],
         peakHourMultipliers: PeakHours, transportModes: [String: TransportModeConfig],
         paymentMethods: [String: PaymentMethodConfig], lines: [String: LineConfig] = [:],
         enforceOperatingHours: Bool = true) {
        self.version = version
        self.stations = stations
        self.edges = edges
        self.peakHourMultipliers = peakHourMultipliers
        self.transportModes = transportModes
        self.paymentMethods = paymentMethods
        self.lines = lines
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
        lines                = try c.decodeIfPresent([String: LineConfig].self,   forKey: .lines) ?? [:]
        enforceOperatingHours = try c.decodeIfPresent(Bool.self, forKey: .enforceOperatingHours) ?? true
    }
}

// MARK: - Route Request / Result

struct RouteRequest {
    enum CostStrategy { case balanced, fastest, cheapest }

    /// Virtual station IDs injected when routing from/to a raw coordinate.
    static let virtualOriginID: StationID = "__ORIGIN__"
    static let virtualDestID: StationID   = "__DEST__"

    let originID: StationID
    let destinationID: StationID
    /// Non-nil when the user tapped the map or used GPS for the start point.
    /// When set, originID must equal `virtualOriginID`.
    let originCoordinate: Coordinates?
    /// Non-nil when the user tapped the map or used GPS for the end point.
    /// When set, destinationID must equal `virtualDestID`.
    let destinationCoordinate: Coordinates?
    let preferredPayments: Set<PaymentMethod>   // empty = accept any
    let allowedModes: Set<TransportMode>         // empty = allow all (except walk is always allowed)
    let departureTime: Date                      // used for peak-hour factor
    let costStrategy: CostStrategy

    init(
        from originID: StationID,
        to destinationID: StationID,
        originCoordinate: Coordinates? = nil,
        destinationCoordinate: Coordinates? = nil,
        preferredPayments: Set<PaymentMethod> = [],
        allowedModes: Set<TransportMode> = [],
        departureTime: Date = .now,
        costStrategy: CostStrategy = .balanced
    ) {
        self.originID = originID
        self.destinationID = destinationID
        self.originCoordinate = originCoordinate
        self.destinationCoordinate = destinationCoordinate
        self.preferredPayments = preferredPayments
        self.allowedModes = allowedModes
        self.departureTime = departureTime
        self.costStrategy = costStrategy
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

    /// True for the synthetic walk between the user's pinned coordinate and the first/last
    /// stop — as opposed to an `INTERCHANGE` walk between two platforms inside the network.
    var isAccessWalk: Bool { line == "ACCESS_WALK" }

    /// The real stop at the network end of an access walk (the other end is the virtual
    /// `__ORIGIN__`/`__DEST__` node, which also carries the `ACCESS_WALK` line).
    var accessStop: Station? {
        guard isAccessWalk else { return nil }
        return fromStation.line == "ACCESS_WALK" ? toStation : fromStation
    }

    /// An access walk past what that stop's role justifies. Surfaced in the UI so a long
    /// walk reads as a visible trade-off rather than a silent one.
    var isLongAccessWalk: Bool {
        guard let stop = accessStop else { return false }
        return distanceKm > AccessPolicy.comfortableRadiusKm(for: stop)
    }
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

struct RouteOption: Identifiable {
    enum Label { case fastest, cheapest, balanced }

    /// Stable for as long as the option is on screen — including across walk refinement,
    /// which sharpens an option's geometry but does not make it a different option.
    ///
    /// Refinement lands a network round-trip *after* the results panel is already up, and
    /// it rebuilds every option. While those rebuilds minted a fresh id, the panel's
    /// `selectedID` matched nothing for one layout pass: every card rendered collapsed,
    /// the panel's height snapped to that shorter measurement, and the expanded card —
    /// still mid-spring — was sliced off by the scroll view's bounds. Carrying the id
    /// through the rebuild is what keeps the selection, an open detail view and the
    /// summary cache pointing at the option they were pointing at a moment earlier.
    ///
    /// Still a `UUID` and still fresh per search, so it also remains what tells the
    /// refiner its results are stale (see `refineWalkLegs`).
    let id: UUID
    let result: RouteResult
    let label: Label

    init(result: RouteResult, label: Label, id: UUID = UUID()) {
        self.result = result
        self.label = label
        self.id = id
    }
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

// MARK: - Access Walk Policy

/// Governs the synthetic walk between a pinned coordinate (address, GPS, map pin) and
/// the first/last real stop of a route.
///
/// The old policy was a single flat 1.5 km radius applied to the *k nearest stops
/// globally*, which failed in both directions: it silently accepted 1.4 km walks to
/// an arbitrary mid-route stop, and — because the nearest stops around any dense point
/// all belong to the same line — it could hand every access edge to one line and leave
/// a slightly-further line with no way in, reporting "no route" for a trip that exists.
///
/// The replacement is role-aware: people will walk to a *terminal* (that's where you
/// board for a long trip), but not nearly as far to a random stop mid-route.
/// `nonisolated` because the module defaults to `@MainActor` isolation and this policy is
/// read from inside `TransitGraphEngine`'s actor during the search.
nonisolated enum AccessPolicy {
    /// Comfortable walk to an ordinary mid-route stop.
    static let midRouteKm: Double = 0.6
    /// Terminals earn a longer allowance — walking to a terminal is normal behaviour.
    static let terminalKm: Double = 1.2
    /// Absolute ceiling. Past this the location is simply not served by the network,
    /// and the user is told so explicitly instead of getting a bare "no route".
    static let hardCeilingKm: Double = 1.5

    /// Access walking is weighted heavier than riding when A* compares alternatives, so
    /// a 1.2 km walk never wins over a 300 m one just to shave a couple of riding
    /// minutes. Applies to search cost only — displayed durations stay honest.
    static let discomfortFactor: Double = 1.6

    /// Upper bound on how many distinct lines get an access edge, to keep the frontier small.
    static let maxLines = 8

    static let walkSpeedKmPerMin = 4.5 / 60.0   // 4.5 km/h
    /// Straight-line distance underestimates a real walk; this approximates street detour.
    static let detourFactor = 1.3

    /// How far a passenger is assumed to walk to reach `station` without complaint.
    static func comfortableRadiusKm(for station: Station) -> Double {
        station.isTerminal ? terminalKm : midRouteKm
    }

    /// Straight-line km → walking minutes, detour included.
    static func walkMinutes(forKm km: Double) -> Double {
        km * detourFactor / walkSpeedKmPerMin
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
    /// Decoded from JSON — line id → display name, e.g. "UPLB_KANAN" → "UPLB Kanan".
    /// Read by `buildLegInstruction`; never a raw line key hardcoded into instruction text.
    let lines: [String: LineConfig]

    /// Mode IDs where `isAlwaysAllowed = true` (e.g. "walk").
    /// Derived once at init from JSON so A* never hard-codes mode strings.
    private let alwaysAllowedModes: Set<String>
    /// ID of the always-allowed walk mode (used for synthetic access-walk edges).
    private let walkModeID: String
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
        lines = graph.lines

        // Derive the always-allowed set from JSON data — no hardcoded mode strings.
        alwaysAllowedModes = Set(
            graph.transportModes.values
                .filter(\.isAlwaysAllowed)
                .map(\.id)
        )
        walkModeID = graph.transportModes.values.first(where: \.isAlwaysAllowed)?.id ?? "walk"
        enforceOperatingHours = graph.enforceOperatingHours
    }

    // MARK: - Public API

    enum RouteError: Error {
        case stationsClosed(closeTime: String)
        /// No stop within `AccessPolicy.hardCeilingKm` of the pinned start point.
        /// Carries the nearest stop so the UI can say *why*, not just "no route".
        case originTooFar(nearest: String, km: Double)
        /// No stop within `AccessPolicy.hardCeilingKm` of the pinned end point.
        case destinationTooFar(nearest: String, km: Double)
        case noPath
    }

    func findRoute(_ request: RouteRequest) -> Result<RouteResult, RouteError> {
        // Station existence check — skip virtual IDs (they won't be in stationMap).
        for stationID in [request.originID, request.destinationID] {
            guard stationID.hasPrefix("__") || stationMap[stationID] != nil else {
                return .failure(.noPath)
            }
        }

        guard request.originID != request.destinationID else {
            return .success(RouteResult(legs: [], totalTimeMinutes: 0, totalFare: 0,
                                        totalDistanceKm: 0, transfers: 0, modes: []))
        }

        // Two coordinate endpoints that land on (near-)the same spot — e.g. the same address
        // typed on both sides — would otherwise route a nonsense station-and-back trip.
        if let originCoord = request.originCoordinate,
           let destCoord = request.destinationCoordinate,
           haversine(from: originCoord, to: destCoord) < 0.1 {
            return .success(RouteResult(legs: [], totalTimeMinutes: 0, totalFare: 0,
                                        totalDistanceKm: 0, transfers: 0, modes: []))
        }

        // Pre-flight operating hours — skip for virtual nodes (always passable).
        if enforceOperatingHours {
            let depHour   = Calendar.current.component(.hour,   from: request.departureTime)
            let depMinute = Calendar.current.component(.minute, from: request.departureTime)
            let departureMinutes = depHour * 60 + depMinute

            for stationID in [request.originID, request.destinationID] where !stationID.hasPrefix("__") {
                guard let station = stationMap[stationID] else { continue }
                if !stationOpen(station, arrivalMinutes: departureMinutes, isAlwaysAllowed: false) {
                    return .failure(.stationsClosed(closeTime: station.operatingHours.close))
                }
            }
        }

        // Pre-flight reachability — a pinned point with nothing inside the hard ceiling can
        // never route, and the user deserves the reason rather than a bare "no route found".
        if let coord = request.originCoordinate, let miss = unreachable(coord) {
            return .failure(.originTooFar(nearest: miss.name, km: miss.km))
        }
        if let coord = request.destinationCoordinate, let miss = unreachable(coord) {
            return .failure(.destinationTooFar(nearest: miss.name, km: miss.km))
        }

        // Two passes: first with the comfortable, role-aware radius; only if that finds
        // nothing do we widen to the hard ceiling. A long walk is therefore never chosen
        // when a short one would have done — but it is still offered before giving up,
        // flagged as `isLongAccessWalk` so the UI can call it out.
        let needsWidePass = request.originCoordinate != nil || request.destinationCoordinate != nil
        for widened in (needsWidePass ? [false, true] : [false]) {
            let virtualNodes = buildVirtualNodes(for: request, widened: widened)
            if let result = astar(request: request,
                                  originID: request.originID, destID: request.destinationID,
                                  extraAdj: virtualNodes.adjacency,
                                  extraStations: virtualNodes.stations) {
                return .success(result)
            }
        }
        return .failure(.noPath)
    }

    // MARK: - Virtual Node Helpers

    /// Nearest stop and its distance when *nothing* sits within the hard ceiling of `coord`;
    /// `nil` when the point is served. Returns `nil` for an empty graph too — an unloaded
    /// graph is not a "too far" condition.
    private func unreachable(_ coord: Coordinates) -> (name: String, km: Double)? {
        guard let nearest = stationMap.values
            .map({ (station: $0, dist: haversine(from: coord, to: $0.coordinates)) })
            .min(by: { $0.dist < $1.dist }) else { return nil }
        guard nearest.dist > AccessPolicy.hardCeilingKm else { return nil }
        return (nearest.station.name, nearest.dist)
    }

    /// Assembles the virtual origin/destination nodes and their access edges for one pass.
    private func buildVirtualNodes(
        for request: RouteRequest,
        widened: Bool
    ) -> (adjacency: [StationID: [TransitEdge]], stations: [StationID: Station]) {
        var extraAdj: [StationID: [TransitEdge]] = [:]
        var extraStations: [StationID: Station] = [:]

        if let coord = request.originCoordinate {
            extraStations[RouteRequest.virtualOriginID] = makeVirtualStation(
                id: RouteRequest.virtualOriginID, coord: coord, name: "Your Location")
            let adj = buildAccessEdges(coord: coord, virtualID: RouteRequest.virtualOriginID,
                                       outgoing: true, widened: widened)
            extraAdj.merge(adj) { $0 + $1 }
        }

        if let coord = request.destinationCoordinate {
            extraStations[RouteRequest.virtualDestID] = makeVirtualStation(
                id: RouteRequest.virtualDestID, coord: coord, name: "Your Destination")
            let adj = buildAccessEdges(coord: coord, virtualID: RouteRequest.virtualDestID,
                                       outgoing: false, widened: widened)
            extraAdj.merge(adj) { $0 + $1 }
            extraAdj[RouteRequest.virtualDestID, default: []] = extraAdj[RouteRequest.virtualDestID] ?? []
        }

        return (extraAdj, extraStations)
    }

    private func makeVirtualStation(id: StationID, coord: Coordinates, name: String) -> Station {
        Station(
            id: id, name: name, shortName: name,
            line: "ACCESS_WALK", type: walkModeID,
            coordinates: coord,
            isTerminal: false, isInterchange: false,
            interchangesWith: nil, amenities: [],
            operatingHours: Station.OperatingHours(open: "00:00", close: "23:59"),
            // A dropped pin is not a station and has no doors.
            accessPoints: nil
        )
    }

    /// Builds synthetic walk edges between a virtual node and the reachable real stations.
    /// `outgoing: true`  → edges FROM virtualID TO nearby stations  (origin case)
    /// `outgoing: false` → edges FROM nearby stations TO virtualID  (destination case)
    ///
    /// `widened: false` uses the comfortable, role-aware radius (`AccessPolicy`); `true`
    /// relaxes every candidate to the hard ceiling for the fallback pass.
    ///
    /// Candidates are reduced to **the nearest stop on each line**, not the k nearest stops
    /// overall. Taking the k nearest globally hands every access edge to whichever line is
    /// densest around `coord` — around UPLB's Carabao Park all five nearest stops belong to
    /// UPLB_KANAN — so a line whose stop sits slightly further away gets no way in at all
    /// and the search reports "no route" for a trip that plainly exists.
    private func buildAccessEdges(
        coord: Coordinates,
        virtualID: StationID,
        outgoing: Bool,
        widened: Bool
    ) -> [StationID: [TransitEdge]] {
        let candidates = stationMap.values
            .map { (station: $0, dist: haversine(from: coord, to: $0.coordinates)) }
            .filter { item in
                let limit = widened
                    ? AccessPolicy.hardCeilingKm
                    : AccessPolicy.comfortableRadiusKm(for: item.station)
                return item.dist <= limit
            }

        let nearby = Dictionary(grouping: candidates, by: { $0.station.line })
            .compactMap { $0.value.min { $0.dist < $1.dist } }
            .sorted { $0.dist < $1.dist }
            .prefix(AccessPolicy.maxLines)

        var extraAdj: [StationID: [TransitEdge]] = [:]
        for item in nearby {
            let travelMin = AccessPolicy.walkMinutes(forKm: item.dist)
            let fromID    = outgoing ? virtualID : item.station.id
            let toID      = outgoing ? item.station.id : virtualID

            let edge = TransitEdge(
                id: "\(fromID)_to_\(toID)_access",
                from: fromID, to: toID,
                mode: walkModeID, line: "ACCESS_WALK",
                travelTimeMinutes: travelMin,
                distanceKm: item.dist,
                baseFare: 0, farePerKm: 0,
                acceptedPayments: [],
                isAirConditioned: false,
                crowdFactor: 0, reliability: 1.0,
                bidirectional: false, direction: nil,
                // Deliberately empty — never a [origin, station] chord. A two-point straight
                // line across whatever lies between the pin and the stop (a divided highway,
                // a river, a walled block) is not a path anyone can walk, and once drawn it
                // is indistinguishable from real geometry. WalkRouteRefiner fills this in
                // from MKDirections walking directions; until it does, the leg draws nothing.
                polylineCoordinates: [],
                mkDirectionsTransportType: "walking",
                isRoadSnapped: false
            )
            extraAdj[fromID, default: []].append(edge)
        }
        return extraAdj
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

    private func astar(
        request: RouteRequest,
        originID: StationID,
        destID: StationID,
        extraAdj: [StationID: [TransitEdge]],
        extraStations: [StationID: Station]
    ) -> RouteResult? {
        func effectiveStation(_ id: StationID) -> Station? {
            extraStations[id] ?? stationMap[id]
        }

        guard let destCoords   = effectiveStation(destID)?.coordinates,
              let originCoords = effectiveStation(originID)?.coordinates else { return nil }

        // Wall-clock departure expressed as minutes since midnight.
        let calendar = Calendar.current
        let depHour   = calendar.component(.hour,   from: request.departureTime)
        let depMinute = calendar.component(.minute, from: request.departureTime)
        let departureMinutes = depHour * 60 + depMinute

        // gScore is the *search* cost (includes the access-walk discomfort weight);
        // timeScore is the cost the user is shown. They diverge only on access walks —
        // buildResult derives per-leg durations and arrival times from timeScore so a
        // weighted walk is never displayed as taking longer than it does.
        var gScore: [StationID: Double] = [originID: 0]
        var timeScore: [StationID: Double] = [originID: 0]
        var cameFrom: [StationID: (parent: StationID, edge: TransitEdge)] = [:]
        var closed: Set<StationID> = []
        var openHeap = MinHeap<AStarNode>()
        let originH = heuristic(from: originCoords, to: destCoords)
        openHeap.push(AStarNode(stationID: originID, gCost: 0, hCost: originH))

        while let current = openHeap.popMin() {
            let currentID = current.stationID

            if let bestG = gScore[currentID], current.gCost > bestG { continue }
            if closed.contains(currentID) { continue }
            closed.insert(currentID)

            if currentID == destID {
                return buildResult(
                    destination: destID,
                    cameFrom: cameFrom,
                    gScore: timeScore,
                    stationMap: stationMap,
                    extraStations: extraStations,
                    departureTime: request.departureTime
                )
            }

            // Combine real adjacency with virtual-node edges.
            let neighbors = (adjacency[currentID] ?? []) + (extraAdj[currentID] ?? [])

            for edge in neighbors {
                let neighbor = edge.to
                guard !closed.contains(neighbor) else { continue }

                // ── Payment filter ──────────────────────────────────────────
                // Modes marked isAlwaysAllowed (e.g. walk) bypass both filters.
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

                let effectiveMinutes: Double
                switch request.costStrategy {
                case .balanced:
                    let reliabilityPenalty = rawMinutes * (1.0 - edge.reliability) * 0.2
                    let crowdPenalty       = rawMinutes * edge.crowdFactor * 0.1
                    effectiveMinutes = (rawMinutes * peakMultiplier) + reliabilityPenalty + crowdPenalty
                case .fastest:
                    effectiveMinutes = rawMinutes * peakMultiplier
                case .cheapest:
                    // Weight fare at 1.5 min/peso so fare-heavy routes are penalised relative to time.
                    let fare = (edge.line == "INTERCHANGE" || edge.line == "ACCESS_WALK")
                               ? 0.0 : edge.baseFare + edge.farePerKm * edge.distanceKm
                    effectiveMinutes = rawMinutes * peakMultiplier + fare * 1.5
                }

                // Access walking costs more than it takes: without this weight A* will walk
                // 1.2 km to a stop to shave two riding minutes off, which no passenger does.
                let searchMinutes = edge.line == "ACCESS_WALK"
                    ? effectiveMinutes * AccessPolicy.discomfortFactor
                    : effectiveMinutes

                let tentativeG = (gScore[currentID] ?? .infinity) + searchMinutes
                let tentativeTime = (timeScore[currentID] ?? .infinity) + effectiveMinutes

                // ── Operating-hours filter ──────────────────────────────────
                // Virtual nodes (__ORIGIN__, __DEST__) are always passable.
                if enforceOperatingHours, !neighbor.hasPrefix("__"),
                   let neighborStation = effectiveStation(neighbor) {
                    let arrivalMinutes = departureMinutes + Int(tentativeG)
                    guard stationOpen(neighborStation, arrivalMinutes: arrivalMinutes,
                                      isAlwaysAllowed: isAlwaysAllowed) else { continue }
                }

                if tentativeG < (gScore[neighbor] ?? .infinity),
                   let neighborCoords = effectiveStation(neighbor)?.coordinates {
                    gScore[neighbor] = tentativeG
                    timeScore[neighbor] = tentativeTime
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

        return nil
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

    /// `elapsedMinutes` is A*'s *time* score (`timeScore`), not its search cost — the two
    /// differ by the access-walk discomfort weight, which must never reach the UI.
    private func buildResult(
        destination: StationID,
        cameFrom: [StationID: (parent: StationID, edge: TransitEdge)],
        gScore elapsedMinutes: [StationID: Double],
        stationMap: [StationID: Station],
        extraStations: [StationID: Station],
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
        // path[i].edge is the edge OUT of path[i].stationID toward path[i+1].stationID
        // (it's populated from cameFrom[path[i+1]].edge during the backward walk above,
        // then lands on index i after the reverse). Must index with path[i], not
        // path[i+1] — the latter is always the *next* hop's outgoing edge, and is nil
        // for the very last station, silently dropping the final hop of the route.
        var rawSteps: [RawStep] = []

        for i in 0..<path.count - 1 {
            let fromID = path[i].stationID
            let toID   = path[i + 1].stationID
            guard let edge    = path[i].edge,
                  let fromSt  = extraStations[fromID] ?? stationMap[fromID],
                  let toSt    = extraStations[toID]   ?? stationMap[toID] else { continue }

            let cumulativeMinutes = elapsedMinutes[toID] ?? 0
            let effectiveTime     = cumulativeMinutes - (elapsedMinutes[fromID] ?? 0)
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
            // Pin the ends to the boarding/alighting stations' own coordinates rather
            // than trusting the edge's stored polyline endpoints. The schema *should*
            // guarantee polylineCoordinates[0]/[-1] == station coords, but live data can
            // drift from that (a station move that didn't regenerate its edges, a hand-
            // edited polyline, etc.) — and ContentView draws the origin/destination pins
            // from the station coordinates, not from the polyline. Any mismatch there
            // renders as a visible gap between the pin and the line.
            if !polyline.isEmpty {
                polyline[0] = first.fromStation.coordinates
                polyline[polyline.count - 1] = last.toStation.coordinates
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
        // The line's human name where one exists — "UPLB Kanan" rather than the raw
        // "UPLB_KANAN" key every instruction used to print verbatim. Falls back to the
        // key itself for a line the `lines` config doesn't (yet) cover, which for a
        // cached graph downloaded before this field existed is *every* line — so the
        // sentence degrades to today's raw-key text instead of going blank.
        let lineName = lines[line]?.displayName ?? line
        switch mode {
        case .train:
            let dirLabel = direction.map { " (\($0.capitalized))" } ?? ""
            return "Board \(lineName)\(dirLabel) at \(from.shortName), ride to \(to.shortName) (\(stopsLabel))"
        case .bus:
            let dirLabel = direction.map { " (\($0.capitalized))" } ?? ""
            return "Take \(lineName) bus\(dirLabel) from \(from.shortName) to \(to.shortName) (\(stopsLabel))"
        case .jeepney:
            let dirLabel = direction.map { " (\($0.capitalized))" } ?? ""
            return "Ride jeepney (\(lineName))\(dirLabel) from \(from.shortName) to \(to.shortName)"
        case .tricycle:
            let dirLabel = direction.map { " (\($0.capitalized))" } ?? ""
            return "Take tricycle\(dirLabel) from \(from.shortName) to \(to.shortName)"
        case .walk:
            // Access walks have a virtual node on one end — naming it ("Walk from Your
            // Location to Stop 1") reads as a place the user has never heard of.
            if line == "ACCESS_WALK" {
                return from.line == "ACCESS_WALK"
                    ? "Walk to \(to.shortName)"
                    : "Walk from \(from.shortName) to your destination"
            }
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

// MARK: - Location Fetcher

/// CLLocationManager wrapper for the Commute tab.
///
/// Serves two callers off one manager:
///
/// * a **live feed** (`startTracking`) that keeps the map's location dot current, and
/// * **one-shot fixes** (`requestOnce`) for the "use my location" buttons on the search
///   fields.
///
/// One manager, not two, because `requestLocation()` and `startUpdatingLocation()` do not
/// compose — a `requestLocation()` issued while updates are already running is not
/// honoured. So there is a single feed, and one-shot callers are served from it: the
/// latest fix if one is fresh enough, otherwise the next one to arrive.
///
/// CLLocationManager delivers callbacks on the thread its manager was created on, which is
/// main here. The delegate methods are `nonisolated` because the protocol requires it, and
/// hop back through `Task { @MainActor }` so every access to the state below is provably
/// serialised on main.
final class CommuteLocationFetcher: NSObject, CLLocationManagerDelegate {

    /// Called on the main actor for every fix delivered while `startTracking` is in
    /// effect. Set by whoever owns the dot.
    var onUpdate: ((Coordinates) -> Void)?

    /// A one-shot fix older than this is not worth handing out — better to wait for the
    /// next delivery than to drop a search pin where the passenger was a minute ago.
    private static let freshnessWindow: TimeInterval = 30

    private let manager = CLLocationManager()
    private var latest: Coordinates?
    private var latestAt: Date = .distantPast
    private var isTracking = false
    /// Callers of `requestOnce()` waiting on the next fix.
    ///
    /// An array, not a single slot: origin and destination can both be in flight, and
    /// overwriting one would leave its continuation unresumed — an `await` that never
    /// returns and a search button stuck spinning forever.
    private var waiters: [CheckedContinuation<Coordinates?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        // The dot is drawn at this coordinate, so accuracy is directly visible as the dot
        // standing in the wrong place. `kCLLocationAccuracyHundredMeters` put it up to a
        // block away.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Enough to keep the resting camera and the search fields current, without a fix a
        // second. The map's location dot is `UserAnnotation`, fed by MapKit's own service,
        // so nothing on screen is animated from this feed and a filter here costs nothing.
        manager.distanceFilter = 5
        manager.activityType = .otherNavigation
    }

    // MARK: Live feed

    /// Start delivering fixes to `onUpdate`. Idempotent.
    @MainActor
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            // Picked back up in the authorization callback once the passenger answers.
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// Stop the GPS. Call this when the map goes away — an unattended location feed is the
    /// most expensive thing this app can leave running.
    @MainActor
    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        // A one-shot caller may still be waiting on a fix; leave the manager up for them.
        if waiters.isEmpty { manager.stopUpdatingLocation() }
    }

    // MARK: One-shot

    /// A single fix, for assigning to a search field. Answers from the live feed when one
    /// is running, otherwise starts the manager just long enough to get a fix.
    @MainActor
    func requestOnce() async -> Coordinates? {
        if let latest, Date.now.timeIntervalSince(latestAt) < Self.freshnessWindow {
            return latest
        }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            default:
                resumeWaiters(with: nil)
            }
        }
    }

    // MARK: Delivery

    @MainActor
    private func deliver(_ coord: Coordinates) {
        latest = coord
        latestAt = .now
        resumeWaiters(with: coord)
        if isTracking {
            onUpdate?(coord)
        } else {
            // Nobody left to serve — this run was for a one-shot caller only.
            manager.stopUpdatingLocation()
        }
    }

    @MainActor
    private func resumeWaiters(with coord: Coordinates?) {
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume(returning: coord) }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = Coordinates(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
        Task { @MainActor [weak self] in
            self?.deliver(coord)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.isTracking || !self.waiters.isEmpty {
                    self.manager.startUpdatingLocation()
                }
            case .notDetermined:
                break
            default:
                self.resumeWaiters(with: nil)
                self.manager.stopUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `.locationUnknown` is Core Location saying "not yet" — it keeps trying on its
        // own, so failing the waiters here would abandon a fix that is still coming.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor [weak self] in
            self?.resumeWaiters(with: nil)
        }
    }
}

// MARK: - ViewModel

@Observable
final class RouteStore {

    // MARK: State
    var originID: StationID = ""
    var destinationID: StationID = ""
    /// Non-nil when origin was set via GPS or map long-press.
    var originCoordinate: Coordinates?
    /// Non-nil when destination was set via GPS or map long-press.
    var destinationCoordinate: Coordinates?
    var selectedPayments: Set<PaymentMethod> = [.cash]
    var selectedModes: Set<TransportMode> = Set(TransportMode.allCases.filter { $0 != .walk })
    var departureTime: Date = .now
    var useScheduledTime: Bool = false

    var routeResult: RouteResult?
    var routeOptions: [RouteOption] = []
    var isLoading: Bool = false
    var isLocating: Bool = false
    var errorMessage: String?
    var allStations: [Station] = []
    var searchQuery: String = ""
    var filteredStations: [Station] = []

    // MARK: Address Search — LocationSuggestion state
    // Implementation (MKLocalSearchCompleter wiring, merging, invalidation) lives in
    // LocationSearch.swift so this file stays MapKit-free. See FEATURE_ADDRESS_ROUTING_FINDINGS.md §2.
    var originSuggestions: [LocationSuggestion] = []
    var destSuggestions: [LocationSuggestion] = []
    var showOriginSuggestions = false
    var showDestSuggestions = false
    var isResolvingOrigin = false
    var isResolvingDestination = false
    /// Text of the last confirmed origin/destination selection (station, address, pin, swap).
    /// Lets `updateOriginSuggestions`/`updateDestSuggestions` tell a programmatic text-set apart
    /// from a real user edit — see `invalidateOriginIfEdited` in LocationSearch.swift.
    var confirmedOriginLabel: String?
    var confirmedDestLabel: String?
    var lastOriginQuery: String = ""
    var lastDestQuery: String = ""
    let addressSearchOrigin = AddressSearchService()
    let addressSearchDest = AddressSearchService()
    var originDebounce: Task<Void, Never>?
    var destDebounce: Task<Void, Never>?
    /// In-flight MKDirections re-measurement of the current results' walk legs.
    /// Cancelled on every new search so a stale refinement can't overwrite fresh results.
    var walkRefineTask: Task<Void, Never>?

    /// Populated from JSON — drives the mode filter picker UI.
    var availableModes: [TransportModeConfig] = []
    /// Populated from JSON — drives the payment method picker UI.
    var availablePayments: [PaymentMethodConfig] = []

    /// Live position of the passenger, or `nil` until the first fix arrives (or if
    /// location is denied). Read by the map for its location dot and its resting camera,
    /// and rewritten on every fix while `startTrackingUserLocation` is in effect.
    var userLocation: Coordinates?

    private var engine: TransitGraphEngine?
    private let locationFetcher = CommuteLocationFetcher()

    enum LocationTarget { case origin, destination }

    // MARK: Init

    init() {
        // Populate stations immediately from disk cache so search works before
        // the async engine finishes loading (or on subsequent launches).
        self.allStations = StationCache.load()
        addressSearchOrigin.onUpdate = { [weak self] in self?.remergeOriginSuggestions() }
        addressSearchDest.onUpdate = { [weak self] in self?.remergeDestSuggestions() }
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

    /// False until `setupEngine()` finishes. `calculateRoute()` refuses to run before
    /// then, so anything that searches without user input has to wait on this.
    var isEngineReady: Bool { engine != nil }

    @MainActor
    func calculateRoute() async {
        guard let engine else {
            errorMessage = "Transit engine not ready."
            return
        }
        guard canCalculate else {
            errorMessage = "Please select both origin and destination."
            return
        }

        isLoading = true
        errorMessage = nil
        routeResult = nil
        routeOptions = []

        let now: Date = useScheduledTime ? departureTime : .now

        func makeReq(_ strategy: RouteRequest.CostStrategy) -> RouteRequest {
            RouteRequest(
                from: originID, to: destinationID,
                originCoordinate: originCoordinate,
                destinationCoordinate: destinationCoordinate,
                preferredPayments: selectedPayments,
                allowedModes: selectedModes,
                departureTime: now,
                costStrategy: strategy
            )
        }

        let req1 = makeReq(.fastest)
        let req2 = makeReq(.cheapest)
        let req3 = makeReq(.balanced)

        // Run all three strategies; they serialize through the actor's executor but are
        // scheduled as child tasks so the parent suspends only once for all three.
        async let r1 = engine.findRoute(req1)
        async let r2 = engine.findRoute(req2)
        async let r3 = engine.findRoute(req3)
        let (fr, cr, br) = await (r1, r2, r3)

        isLoading = false

        func unwrap(_ r: Result<RouteResult, TransitGraphEngine.RouteError>) -> RouteResult? {
            if case .success(let v) = r {
                return v
            }
            else {
                return nil
            }
        }

        let fastest  = unwrap(fr)
        let cheapest = unwrap(cr)
        let balanced = unwrap(br)

        guard fastest != nil || cheapest != nil || balanced != nil else {
            switch fr {
            case .failure(.stationsClosed(let t)):
                errorMessage = "Stations are closed. MRT/LRT service ends at \(formattedTime(t))."
            case .failure(.originTooFar(let nearest, let km)):
                errorMessage = "Your start point isn't served yet — the nearest stop (\(nearest)) is \(distanceLabel(km)) away."
            case .failure(.destinationTooFar(let nearest, let km)):
                errorMessage = "Your destination isn't served yet — the nearest stop (\(nearest)) is \(distanceLabel(km)) away."
            default:
                errorMessage = "No route found between these locations."
            }
            return
        }

        func routeKey(_ r: RouteResult) -> String {
            r.legs.map { "\($0.line):\($0.fromStation.id):\($0.toStation.id)" }.joined(separator: "|")
        }

        var options: [RouteOption] = []
        var seen = Set<String>()

        func addIfNew(_ result: RouteResult?, label: RouteOption.Label) {
            guard let r = result else { return }
            let key = routeKey(r)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            options.append(RouteOption(result: r, label: label))
        }

        addIfNew(fastest,  label: .fastest)
        addIfNew(cheapest, label: .cheapest)
        addIfNew(balanced, label: .balanced)

        routeOptions = Array(options.prefix(3))
        routeResult  = routeOptions.first?.result

        // Straight-line walks are good enough to search with, not to trust — that goes for
        // the engine's access walks and for the two-point interchange chords stored in JSON
        // alike. Re-measure the ones that survived against real pedestrian directions, off
        // the critical path, so results appear at engine speed and sharpen a moment later.
        // Implementation: WalkRouteRefiner.swift (keeps MapKit out of the domain layer).
        walkRefineTask?.cancel()
        walkRefineTask = Task { [weak self] in await self?.refineWalkLegs() }
    }

    /// Confirms a route selection: sets it as the active map route and dismisses the results panel.
    func selectRoute(_ option: RouteOption) {
        routeResult = option.result
        routeOptions = []
        // Deliberately does NOT cancel `walkRefineTask`. Selecting a route is when the user
        // starts studying the map, which is exactly where a straight-line walk shows — so
        // refinement must be allowed to land on the selected route (WalkRouteRefiner
        // updates `routeResult` in place when the options list has been emptied).
    }

    /// Updates the active map route preview without dismissing the results panel.
    func previewRoute(_ option: RouteOption) {
        routeResult = option.result
    }

    // MARK: Coordinate-based origin / destination

    func setOriginCoordinate(_ coord: Coordinates) {
        originCoordinate = coord
        originID = RouteRequest.virtualOriginID
        confirmedOriginLabel = "Pinned Location"
    }

    func setDestinationCoordinate(_ coord: Coordinates) {
        destinationCoordinate = coord
        destinationID = RouteRequest.virtualDestID
        confirmedDestLabel = "Pinned Location"
    }

    /// Begin following the passenger's own position, for the map's location dot and for
    /// the camera the Commute tab rests at when there is no route to frame.
    ///
    /// Distinct from `fetchLocation(for:)`, which *assigns* a position to a search field.
    /// This one only observes, so a denied or unavailable fix leaves `userLocation` `nil`
    /// and the map falls back to its default region — nothing else changes.
    ///
    /// Pair every call with `stopTrackingUserLocation()`; the feed runs until it is
    /// stopped.
    @MainActor
    func startTrackingUserLocation() {
        locationFetcher.onUpdate = { [weak self] coord in
            self?.userLocation = coord
        }
        locationFetcher.startTracking()
    }

    /// Shut the location feed down. The last known `userLocation` is deliberately kept —
    /// a dot that vanishes on returning to the tab is worse than one that is a moment
    /// stale until the first fix of the new session lands.
    @MainActor
    func stopTrackingUserLocation() {
        locationFetcher.stopTracking()
    }

    /// Fetch the user's current GPS location and assign it to origin or destination.
    @MainActor
    func fetchLocation(for target: LocationTarget) async {
        isLocating = true
        defer { isLocating = false }
        guard let coord = await locationFetcher.requestOnce() else { return }
        switch target {
        case .origin:      setOriginCoordinate(coord)
        case .destination: setDestinationCoordinate(coord)
        }
    }

    // MARK: Helpers

    /// "450 m" under a kilometre, "2.3 km" above — used in the out-of-range messages.
    func distanceLabel(_ km: Double) -> String {
        km < 1 ? "\(Int((km * 1000).rounded(.toNearestOrAwayFromZero) / 10) * 10) m"
               : String(format: "%.1f km", km)
    }

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
        !originID.isEmpty && !destinationID.isEmpty && engine != nil &&
        originID != destinationID
    }
}

// MARK: - Helpers

private extension Double {
    var toRadians: Double { self * .pi / 180 }
}
