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
        ArrivalAlerts.shared.reset()
        guard SettingsKey.isLiveActivitiesEnabled, let engine = commuteEngine else { return }
        CommuteLiveActivityController.shared.start(
            result: engine.result, engine: engine, originName: routeStore.originText,
            destinationName: routeStore.destinationText, now: startedAt, lineName: routeStore.lineDisplayName,
            legColor: routeStore.legColor)
    }

    /// Removes the Live Activity and stops background GPS. Runs on every end of Commute Mode.
    func endLiveActivity() {
        routeStore.setBackgroundLocationUpdates(false)
        ArrivalAlerts.shared.reset()
        CommuteLiveActivityController.shared.end()
    }

    /// Ends the Live Activity as arrived and shows the arrived card. Runs on the last step's tap with Location off.
    func arriveByTap() {
        guard isCommuting, arrivedAt == nil else { return }
        let now = Date()
        CommuteLiveActivityController.shared.endArrived(now: now)
        markArrived(at: now)
    }

    func noteLiveActivityFix(at date: Date) {
        CommuteLiveActivityController.shared.noteFix(at: date)
    }

    /// Pushes progress to the Live Activity. Shows the arrived card when the passenger reaches the end.
    /// With Location off, only a tap on the last step arrives (`arriveByTap()`).
    func tickLiveActivity(now: Date) {
        guard isCommuting, arrivedAt == nil, let engine = commuteEngine else { return }
        ArrivalAlerts.shared.update(engine: engine, destinationName: routeStore.destinationText)
        let isOnLastLeg = engine.currentLegIndex == engine.result.legs.count - 1
        if isOnLastLeg, routeStore.locationAccess != .off,
           engine.metersRemainingOnCurrentLeg <= Self.arrivalRadiusMeters {
            CommuteLiveActivityController.shared.endArrived(now: now)
            markArrived(at: now)
            return
        }
        CommuteLiveActivityController.shared.update(engine: engine, now: now)
    }
}
