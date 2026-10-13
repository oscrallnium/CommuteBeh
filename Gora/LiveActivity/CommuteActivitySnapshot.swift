//
//  CommuteActivitySnapshot.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import Foundation

/// Builds the Live Activity data from a route and the progress engine. Pure functions, no ActivityKit calls.
/// `lineName` maps a line key to its display name from the transit graph.
enum CommuteActivitySnapshot {
    typealias Attributes = CommuteActivityAttributes
    typealias State = CommuteActivityAttributes.ContentState

    /// Seconds without a GPS fix before the system marks the activity stale.
    static let staleAfterSeconds: TimeInterval = 180
    /// Shortest gap between two updates that only change progress or ETA.
    private static let minUpdateGap: TimeInterval = 15
    private static let maxUpdateGap: TimeInterval = 60
    private static let progressStep = 0.01
    private static let etaStepSeconds: TimeInterval = 60

    static func attributes(result: RouteResult, destinationName: String) -> Attributes {
        let weights = result.legs.map { max($0.effectiveTravelMinutes, 0) }
        let total = weights.reduce(0, +)
        var labels: [Attributes.BoundaryLabel] = []
        var elapsed = 0.0
        for (index, leg) in result.legs.enumerated() {
            let position = total > 0 ? elapsed / total : 0
            if index == 0 || leg.line == "INTERCHANGE" {
                labels.append(.init(position: position, text: leg.fromStation.shortName))
            }
            elapsed += weights[index]
        }
        labels.append(.init(position: 1, text: destinationName))
        return Attributes(
            segments: zip(result.legs, weights).map { .init(isWalk: isWalkLike($0), weight: $1) },
            boundaryLabels: labels,
            destinationName: destinationName)
    }

    static func state(result: RouteResult, engine: CommuteProgressEngine, destinationName: String,
                      lastFixAt: Date, now: Date, lineName: (String) -> String) -> State {
        let legs = result.legs
        let index = min(engine.currentLegIndex, max(legs.count - 1, 0))
        let leg = legs[index]
        let isWaiting = isTransferWait(legs: legs, index: index)
        let nextRide = legs.dropFirst(index + 1).first { !isWalkLike($0) }
        return State(
            phase: isWaiting ? .waiting : .live,
            progress: engine.progressFraction,
            eta: now.addingTimeInterval(engine.plannedSecondsRemaining),
            lastFixAt: lastFixAt,
            actionText: leg.instruction,
            legLabel: isWaiting ? "Transfer" : (isWalkLike(leg) ? "Walk" : lineName(leg.line)),
            stopsLeft: stopsLeft(legs: legs, index: index, fraction: engine.fractionAlongCurrentLeg),
            nextLineName: nextRide.map { lineName($0.line) },
            legIndex: index)
    }

    static func arrivedState(from last: State, destinationName: String, now: Date) -> State {
        var state = last
        state.phase = .arrived
        state.progress = 1
        state.eta = now
        state.actionText = "Arrived at \(destinationName)"
        state.stopsLeft = 0
        return state
    }

    /// True when `new` differs from `last` enough to justify an update at `now`.
    static func shouldSend(_ new: State, last: State?, lastSentAt: Date?, now: Date) -> Bool {
        guard let last, let lastSentAt else { return true }
        if new.legIndex != last.legIndex || new.actionText != last.actionText || new.phase != last.phase {
            return true
        }
        let gap = now.timeIntervalSince(lastSentAt)
        guard gap >= minUpdateGap else { return false }
        return abs(new.progress - last.progress) >= progressStep
            || abs(new.eta.timeIntervalSince(last.eta)) >= etaStepSeconds
            || gap >= maxUpdateGap
    }

    private static func isWalkLike(_ leg: RouteLeg) -> Bool {
        leg.mode == .walk || leg.line == "INTERCHANGE"
    }

    private static func isTransferWait(legs: [RouteLeg], index: Int) -> Bool {
        guard isWalkLike(legs[index]), index > 0, index < legs.count - 1 else { return false }
        return !isWalkLike(legs[index - 1]) && !isWalkLike(legs[index + 1])
    }

    private static func stopsLeft(legs: [RouteLeg], index: Int, fraction: Double) -> Int {
        let later = legs.dropFirst(index + 1).filter { !isWalkLike($0) }.reduce(0) { $0 + $1.stopCount }
        guard !isWalkLike(legs[index]) else { return later }
        return later + Int(((1 - fraction) * Double(legs[index].stopCount)).rounded(.up))
    }
}
