//
//  ScheduledBoarding.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import Foundation

/// The wait before a vehicle of a scheduled line, and the time it leaves the boarding stop.
nonisolated struct ScheduledWait: Sendable {
    let departure: Date
    let minutes: Double
}

/// Boarding rules of the lines that have a timetable. Timetable times are departures from the
/// first stop of a line in one direction; a later stop sees the vehicle after its ride offset.
nonisolated struct ScheduledBoarding: Sendable {
    private struct Key: Hashable {
        let line: String
        let direction: String?
    }

    private let lines: Set<String>
    private let offsets: [Key: [StationID: Double]]

    init(timetable: ServiceTimetable, edges: [StationID: [TransitEdge]]) {
        var grouped: [Key: [TransitEdge]] = [:]
        var scheduled: Set<String> = []
        for edge in edges.values.joined() where timetable.hasTimetable(line: edge.line) {
            scheduled.insert(edge.line)
            grouped[Key(line: edge.line, direction: edge.direction), default: []].append(edge)
        }
        lines = scheduled
        offsets = grouped.mapValues(Self.rideOffsets)
    }

    var hasScheduledLines: Bool { !lines.isEmpty }

    func isScheduled(line: String) -> Bool {
        !lines.isEmpty && lines.contains(line)
    }

    /// Ride minutes from the first stop of the line and direction to `station`. 0 when unknown.
    func offsetMinutes(line: String, direction: String?, station: StationID) -> Double {
        offsets[Key(line: line, direction: direction)]?[station] ?? 0
    }

    /// Ride minutes from each first stop to every stop reached. A first stop has no incoming edge.
    /// A line whose edges form a cycle with no first stop returns an empty map.
    static func rideOffsets(_ edges: [TransitEdge]) -> [StationID: Double] {
        var outgoing: [StationID: [TransitEdge]] = [:]
        var entered: Set<StationID> = []
        for edge in edges {
            outgoing[edge.from, default: []].append(edge)
            entered.insert(edge.to)
        }
        var result: [StationID: Double] = [:]
        for start in outgoing.keys where !entered.contains(start) {
            var visited: Set<StationID> = [start]
            var stack: [(StationID, Double)] = [(start, 0)]
            while let (node, minutes) = stack.popLast() {
                result[node] = min(result[node] ?? .infinity, minutes)
                for edge in outgoing[node] ?? [] where visited.insert(edge.to).inserted {
                    stack.append((edge.to, minutes + edge.travelTimeMinutes))
                }
            }
        }
        return result
    }

    /// The first vehicle that passes the boarding stop at or after `arrive`. Nil when the
    /// timetable lists no departure within its look-ahead.
    static func wait(
        arrive: Date, offsetMinutes: Double, line: String, direction: String?,
        timetable: ServiceTimetable
    ) -> ScheduledWait? {
        let offset = offsetMinutes * 60
        guard let terminal = timetable.nextDeparture(
            line: line, direction: direction, atOrAfter: arrive.addingTimeInterval(-offset)
        ) else { return nil }
        let passes = terminal.addingTimeInterval(offset)
        return ScheduledWait(departure: passes, minutes: max(0, passes.timeIntervalSince(arrive) / 60))
    }
}

extension TransitGraphEngine {
    /// True when a ride edge starts a new boarding: no incoming edge, a walk-like incoming edge,
    /// or an incoming edge of another line or direction.
    func startsBoarding(_ edge: TransitEdge, arrivedVia incoming: TransitEdge?) -> Bool {
        guard let incoming else { return true }
        return isWalkLikeEdge(incoming) || incoming.line != edge.line
            || incoming.direction != edge.direction
    }

    /// The wait for a scheduled boarding at `edge.from`, or nil when no vehicle runs in the look-ahead.
    func scheduledWait(for edge: TransitEdge, arrive: Date) -> ScheduledWait? {
        ScheduledBoarding.wait(
            arrive: arrive,
            offsetMinutes: scheduledBoarding.offsetMinutes(
                line: edge.line, direction: edge.direction, station: edge.from),
            line: edge.line, direction: edge.direction, timetable: timetable
        )
    }
}
