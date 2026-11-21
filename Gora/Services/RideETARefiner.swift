//
//  RideETARefiner.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/17/26.
//

import Foundation

/// Apple driving ETAs for road rides. The graph time stays the fallback for a leg whose request fails.
enum RideETA {
    static let bucketSeconds: TimeInterval = 900
    static let maxConcurrent = 4

    /// One ETA request. Legs with the same stations and departure bucket share it.
    nonisolated struct Key: Hashable {
        let from: StationID
        let to: StationID
        let bucket: Int
    }

    nonisolated struct Request {
        let key: Key
        let from: Coordinates
        let to: Coordinates
        let departure: Date
    }

    /// The time the vehicle leaves: the leg arrival minus the leg ride time.
    static func departure(of leg: RouteLeg) -> Date {
        leg.estimatedArrival.addingTimeInterval(-leg.effectiveTravelMinutes * 60)
    }

    static func key(for leg: RouteLeg) -> Key {
        let bucket = Int(departure(of: leg).timeIntervalSince1970 / bucketSeconds)
        return Key(from: leg.fromStation.id, to: leg.toStation.id, bucket: bucket)
    }

    /// One request per distinct key across the results, in first-seen order.
    static func requests(for results: [RouteResult]) -> [Request] {
        var seen: Set<Key> = []
        var requests: [Request] = []
        for leg in results.flatMap(\.legs) where RoadTraffic.isRoadLeg(leg) {
            let key = key(for: leg)
            guard seen.insert(key).inserted else { continue }
            requests.append(Request(key: key, from: leg.fromStation.coordinates,
                                    to: leg.toStation.coordinates, departure: departure(of: leg)))
        }
        return requests
    }

    /// Minutes per key. A key with no entry failed or timed out. At most `maxConcurrent` run at once.
    nonisolated static func fetch(_ requests: [Request]) async -> [Key: Double] {
        var results: [Key: Double] = [:]
        await withTaskGroup(of: (Key, Double?).self) { group in
            var next = 0
            while next < min(maxConcurrent, requests.count) {
                let request = requests[next]
                group.addTask { (request.key, await minutes(for: request)) }
                next += 1
            }
            while let (key, minutes) = await group.next() {
                if let minutes { results[key] = minutes }
                guard next < requests.count, !Task.isCancelled else { continue }
                let request = requests[next]
                group.addTask { (request.key, await Self.minutes(for: request)) }
                next += 1
            }
        }
        return results
    }

    private nonisolated static func minutes(for request: Request) async -> Double? {
        if let cached = await RideETACache.shared.minutes(for: request.key) { return cached }
        guard let seconds = await DirectionsGateway.shared.travelSeconds(
                  from: request.from, to: request.to, departure: request.departure,
                  cacheOnDisk: false, urgency: .interactive),
              seconds > 0 else { return nil }
        await RideETACache.shared.store(seconds / 60, for: request.key)
        return seconds / 60
    }
}

/// Session cache of Apple ETAs, keyed by station pair and 15-minute departure bucket.
private actor RideETACache {
    static let shared = RideETACache()
    private var entries: [RideETA.Key: Double] = [:]

    func minutes(for key: RideETA.Key) -> Double? { entries[key] }
    func store(_ minutes: Double, for key: RideETA.Key) { entries[key] = minutes }
}

@MainActor
extension RouteStore {

    /// Replaces each road ride time with the Apple ETA, in place. Order, labels, and ids stay.
    /// Writes nothing when the options list changed during the requests.
    func refineRideETAs() async {
        let snapshot = routeOptions
        let selected = routeResult
        let results = snapshot.isEmpty ? [selected].compactMap { $0 } : snapshot.map(\.result)
        let requests = RideETA.requests(for: results)
        guard !requests.isEmpty else { return }

        let minutes = await RideETA.fetch(requests)
        guard !Task.isCancelled, !minutes.isEmpty else { return }

        guard !snapshot.isEmpty else {
            guard routeOptions.isEmpty, let selected, routeResult?.legs.first?.id == selected.legs.first?.id
            else { return }
            routeResult = selected.replacingRideMinutes(minutes)
            return
        }
        guard routeOptions.map(\.id) == snapshot.map(\.id) else {
            if routeOptions.isEmpty, let selected, routeResult?.legs.first?.id == selected.legs.first?.id {
                routeResult = selected.replacingRideMinutes(minutes)
            }
            return
        }

        let shownIndex = snapshot.firstIndex { $0.result.legs.first?.id == routeResult?.legs.first?.id }
        let rebuilt = snapshot.map {
            $0.replacing(result: $0.result.replacingRideMinutes(minutes))
        }
        routeOptions = rebuilt
        if let shownIndex { routeResult = rebuilt[shownIndex].result }
    }
}

extension RouteResult {
    /// Sets each road leg to its Apple ETA and moves every later arrival by the running difference.
    /// A scheduled boarding keeps its `waitMinutes`.
    func replacingRideMinutes(_ minutes: [RideETA.Key: Double]) -> RouteResult {
        var legs: [RouteLeg] = []
        var shift: Double = 0
        for leg in self.legs {
            guard RoadTraffic.isRoadLeg(leg), let apple = minutes[RideETA.key(for: leg)] else {
                legs.append(leg.shiftingArrival(byMinutes: shift))
                continue
            }
            shift += apple - leg.effectiveTravelMinutes
            legs.append(leg.copy(
                effectiveTravelMinutes: apple,
                estimatedArrival: leg.estimatedArrival.addingTimeInterval(shift * 60)
            ))
        }
        return replacingLegs(legs)
    }
}
