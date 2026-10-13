//
//  ContentView+LiveActivity.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import Foundation

// MARK: - Live Activity and background tracking
//
// Hooks that connect Commute Mode to `CommuteLiveActivityController`. See `Commute.md`.

extension ContentView {

    /// Meters from the end of the last leg at which the passenger counts as arrived.
    private static let arrivalRadiusMeters: Double = 30

    /// Starts the Live Activity and keeps GPS running in the background for the commute.
    func beginLiveActivity(startedAt: Date) {
        routeStore.setBackgroundLocationUpdates(true)
        guard let engine = commuteEngine else { return }
        CommuteLiveActivityController.shared.start(
            result: engine.result, engine: engine, destinationName: destinationText,
            now: startedAt, lineName: routeStore.lineDisplayName)
    }

    /// Removes the Live Activity and stops background GPS. Runs on every end of Commute Mode.
    func endLiveActivity() {
        routeStore.setBackgroundLocationUpdates(false)
        CommuteLiveActivityController.shared.end()
    }

    func noteLiveActivityFix(at date: Date) {
        CommuteLiveActivityController.shared.noteFix(at: date)
    }

    /// Pushes progress to the Live Activity. Shows the arrived card when the passenger reaches the end.
    func tickLiveActivity(now: Date) {
        guard isCommuting, arrivedAt == nil, let engine = commuteEngine else { return }
        let isOnLastLeg = engine.currentLegIndex == engine.result.legs.count - 1
        if isOnLastLeg, engine.metersRemainingOnCurrentLeg <= Self.arrivalRadiusMeters {
            CommuteLiveActivityController.shared.endArrived(now: now)
            markArrived(at: now)
            return
        }
        CommuteLiveActivityController.shared.update(engine: engine, now: now)
    }
}
