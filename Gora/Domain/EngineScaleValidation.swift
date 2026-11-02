//
//  EngineScaleValidation.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

#if DEBUG

// Standalone check, like `TrackSnapperValidation`: no test target exists yet.
// `EngineScaleValidation.runAll()` can run from anywhere in a debug build.

import CoreLocation
import Foundation

nonisolated enum EngineScaleValidation {

    private static let lineCounts = [36, 150, 400]
    private static let stopsPerLine = 50
    private static let routesPerSize = 20

    /// Runs every size, prints `[EngineScale]` timings, and returns true when all equality checks pass.
    static func runAll() async -> Bool {
        var allPassed = true
        var previousTotalMs: Double?
        for lineCount in lineCounts {
            let graph = makeGraph(lineCount: lineCount)
            let transfersMatch = transfersMatchReference(graph)
            allPassed = allPassed && transfersMatch

            let clock = ContinuousClock()
            let initStart = clock.now
            let engine = TransitGraphEngine(graph: graph)
            let initMs = milliseconds(clock.now - initStart)

            let requests = makeRequests(graph: graph)
            let routeStart = clock.now
            var found = 0
            for request in requests {
                if case .success(let result) = await engine.findRoute(request), !result.isEmpty { found += 1 }
            }
            let routeMs = milliseconds(clock.now - routeStart)

            let totalMs = initMs + routeMs
            let growth = previousTotalMs.map { String(format: "%.2fx", totalMs / $0) } ?? "base"
            print("[EngineScale] lines=\(lineCount) stations=\(graph.stations.count) edges=\(graph.edges.count) "
                + "transfersMatch=\(transfersMatch)")
            print("[EngineScale]   init=\(format(initMs)) ms, \(requests.count) routes=\(format(routeMs)) ms "
                + "(\(format(routeMs / Double(requests.count))) ms each, \(found) found), growth=\(growth)")
            previousTotalMs = totalMs
        }
        print("[EngineScale] result=\(allPassed ? "pass" : "FAIL")")
        return allPassed
    }

    // MARK: - Equality check

    private static func transfersMatchReference(_ graph: TransitGraph) -> Bool {
        let grid = TransferPolicy.edges(stations: graph.stations, existing: graph.edges, walkModeID: "walk")
        let reference = referenceTransfers(stations: graph.stations, existing: graph.edges, walkModeID: "walk")
        guard grid.count == reference.count else { return false }
        return zip(grid, reference).allSatisfy {
            $0.id == $1.id && $0.distanceKm == $1.distanceKm && $0.travelTimeMinutes == $1.travelTimeMinutes
        }
    }

    /// Nested loop over all pairs. A latitude test drops pairs that are far apart before the
    /// distance call, so the 400-line graph finishes in seconds.
    private static func referenceTransfers(
        stations: [Station], existing: [TransitEdge], walkModeID: String
    ) -> [TransitEdge] {
        let linked = Set(existing.filter { $0.line == "INTERCHANGE" }.flatMap {
            ["\($0.from)|\($0.to)", "\($0.to)|\($0.from)"]
        })
        let located = stations.map {
            ($0, CLLocation(latitude: $0.coordinates.lat, longitude: $0.coordinates.lng))
        }
        let keys = stations.map(StationChain.key(of:))
        let latitudeLimit = TransferPolicy.maxKm / 100

        var result: [TransitEdge] = []
        for (i, (a, locationA)) in located.enumerated() {
            for j in (i + 1)..<max(located.count, i + 1) {
                let (b, locationB) = located[j]
                guard abs(a.coordinates.lat - b.coordinates.lat) <= latitudeLimit,
                      keys[i] != keys[j],
                      !linked.contains("\(a.id)|\(b.id)") else { continue }
                let km = locationA.distance(from: locationB) / 1000
                guard km <= TransferPolicy.maxKm else { continue }
                result.append(referenceTransfer(from: a, to: b, km: km, walkModeID: walkModeID))
                result.append(referenceTransfer(from: b, to: a, km: km, walkModeID: walkModeID))
            }
        }
        return result
    }

    private static func referenceTransfer(from: Station, to: Station, km: Double, walkModeID: String) -> TransitEdge {
        makeEdge(id: "TRANSFER_\(from.id)_\(to.id)", from: from, to: to, mode: walkModeID,
                 line: "INTERCHANGE", minutes: AccessPolicy.walkMinutes(forKm: km) + TransferPolicy.boardingMinutes,
                 km: km, bidirectional: false)
    }

    // MARK: - Synthetic graph

    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static let modeCycle = ["train", "bus", "jeepney"]

    private static func makeGraph(lineCount: Int) -> TransitGraph {
        var random = Generator()
        var stations: [Station] = []
        var edges: [TransitEdge] = []

        for line in 0..<lineCount {
            let lineID = "L\(line)"
            let mode = modeCycle[line % modeCycle.count]
            var lat = 14.50 + random.next() * 0.20
            var lng = 121.00 + random.next() * 0.10
            var bearing = random.next() * 2 * .pi
            var previous: Station?
            for stop in 1...stopsPerLine {
                let station = makeStation(id: "\(lineID)_S\(stop)", line: lineID, mode: mode,
                                          lat: lat, lng: lng, terminal: stop == 1 || stop == stopsPerLine)
                stations.append(station)
                if let previous {
                    edges.append(makeEdge(id: "\(lineID)_E\(stop)", from: previous, to: station, mode: mode,
                                          line: lineID, minutes: 1.5, km: 0.4, bidirectional: true))
                }
                previous = station
                bearing += (random.next() - 0.5) * 0.3
                lat += 0.4 * cos(bearing) / 111.0
                lng += 0.4 * sin(bearing) / (111.32 * cos(lat * .pi / 180))
            }
        }
        return TransitGraph(
            version: "synthetic", stations: stations, edges: edges,
            peakHourMultipliers: makePeaks(), transportModes: makeModes(), paymentMethods: [:])
    }

    private static func makeStation(id: String, line: String, mode: String,
                                    lat: Double, lng: Double, terminal: Bool) -> Station {
        Station(
            id: id, name: "Stop \(id)", shortName: id, line: line, type: mode,
            coordinates: Coordinates(lat: lat, lng: lng),
            isTerminal: terminal, isInterchange: false, interchangesWith: nil, amenities: [],
            operatingHours: Station.OperatingHours(open: "00:00", close: "23:59"),
            accessPoints: nil, sequence: nil, boarding: nil)
    }

    private static func makeEdge(id: String, from: Station, to: Station, mode: String, line: String,
                                 minutes: Double, km: Double, bidirectional: Bool) -> TransitEdge {
        TransitEdge(
            id: id, from: from.id, to: to.id, mode: mode, line: line,
            travelTimeMinutes: minutes, distanceKm: km, baseFare: 13, farePerKm: 1.5,
            acceptedPayments: ["cash"], isAirConditioned: false, crowdFactor: 0.2, reliability: 0.9,
            bidirectional: bidirectional, direction: nil,
            polylineCoordinates: [from.coordinates, to.coordinates],
            mkDirectionsTransportType: "transit", isRoadSnapped: false)
    }

    private static func makePeaks() -> TransitGraph.PeakHours {
        func peak(_ start: String, _ end: String, _ factor: Double, _ modes: [String]) -> PeakHourMultiplier {
            PeakHourMultiplier(timeRange: .init(start: start, close: end),
                               travelTimeMultiplier: factor, modes: modes)
        }
        return TransitGraph.PeakHours(
            morningPeak: peak("07:00", "09:00", 1.3, ["bus", "jeepney"]),
            eveningPeak: peak("17:00", "19:00", 1.3, ["bus", "jeepney"]),
            trainPeak: peak("07:00", "09:00", 1.1, ["train"]))
    }

    private static func makeModes() -> [String: TransportModeConfig] {
        Dictionary(uniqueKeysWithValues: (modeCycle + ["walk"]).map { id in
            (id, TransportModeConfig(
                id: id, displayName: id, pluralName: id, sfSymbol: "figure.walk", colorHex: "#000000",
                mapLineWidthPt: 3, mapLineDash: [], mkDirectionsTransportType: "transit",
                isUserSelectable: id != "walk", isAlwaysAllowed: id == "walk",
                lines: [], defaultAcceptedPayments: ["cash"], notes: ""))
        })
    }

    // MARK: - Requests

    /// Pins sit within 100 m of random stations, so every request has stops in reach.
    private static func makeRequests(graph: TransitGraph) -> [RouteRequest] {
        var random = Generator(state: 42)
        let departure = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        let strategies: [RouteRequest.CostStrategy] = [.balanced, .fastest, .cheapest]

        func pin() -> Coordinates {
            let station = graph.stations[Int(random.next() * Double(graph.stations.count))]
            return Coordinates(lat: station.coordinates.lat + 0.0005, lng: station.coordinates.lng + 0.0005)
        }
        return (0..<routesPerSize).flatMap { _ in
            let origin = pin()
            let destination = pin()
            return strategies.map {
                RouteRequest(from: RouteRequest.virtualOriginID, to: RouteRequest.virtualDestID,
                             originCoordinate: origin, destinationCoordinate: destination,
                             departureTime: departure, costStrategy: $0)
            }
        }
    }

    // MARK: - Formatting

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

#endif
