//
//  ContentView+CommutePersistence.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI
import os

private let commuteLog = Logger(subsystem: "com.banaueinc.gora", category: "Commute")

/// Why Commute Mode ended. Written to the log by `endCommute(reason:)`.
enum CommuteEndReason: String {
    /// The passenger tapped "End commute" or "Done".
    case user
    /// The debug simulation stopped.
    case debugStop
}

// MARK: - Save, restore, arrival
//
// Keeps the active commute on disk so it survives app termination. See `Commute.md`.

extension ContentView {

    /// Set once per launch so a tab switch never repeats the restore.
    private static var didAttemptRestore = false

    /// True while the debug simulator owns the passenger position.
    private var isSimulatingCommute: Bool {
        #if DEBUG
        routeStore.isLocationSimulated
        #else
        false
        #endif
    }

    /// Enters Commute Mode now and starts the Live Activity.
    func startCommute(with option: RouteOption) {
        let startedAt = Date()
        enterCommuteMode(with: option, startedAt: startedAt)
        beginLiveActivity(startedAt: startedAt)
        if isSimulatingCommute { ActiveCommuteStore.clear() } else { saveCommute() }
    }

    func logCommuteEnd(_ reason: CommuteEndReason) {
        commuteLog.info("endCommute reason=\(reason.rawValue, privacy: .public)")
    }

    /// Writes the running commute to disk. Does nothing for a simulation or an arrived commute.
    func saveCommute() {
        guard isCommuting, arrivedAt == nil, !isSimulatingCommute,
              let engine = commuteEngine, let startedAt = commuteStartedAt else { return }
        ActiveCommuteStore.save(SavedCommute(result: engine.result, startedAt: startedAt,
                                             originText: originText, destinationText: destinationText,
                                             savedAt: .now))
    }

    /// Resumes the saved commute with its first start time and reattaches its Live Activity.
    /// Ends leftover Live Activities when there is nothing to resume.
    func restoreCommuteIfNeeded() async {
        guard !Self.didAttemptRestore else { return }
        Self.didAttemptRestore = true
        guard !isCommuting else { return }
        let stored = ActiveCommuteStore.load()
        guard let saved = stored, saved.isRestorable(at: .now) else {
            if stored != nil { commuteLog.info("discarded saved commute") }
            ActiveCommuteStore.clear()
            await CommuteLiveActivityController.shared.endOrphans()
            return
        }
        originText = saved.originText
        destinationText = saved.destinationText
        enterCommuteMode(with: RouteOption(result: saved.result, label: .fastest), startedAt: saved.startedAt)
        routeStore.setBackgroundLocationUpdates(true)
        guard let engine = commuteEngine else { return }
        CommuteLiveActivityController.shared.reattach(
            result: engine.result, engine: engine, destinationName: saved.destinationText,
            startedAt: saved.startedAt, lineName: routeStore.lineDisplayName)
        commuteLog.info("restored commute started \(saved.startedAt, privacy: .public)")
    }

    /// Shows the arrived card and drops the saved commute. The card stays until the passenger taps Done.
    func markArrived(at now: Date) {
        commuteLog.info("arrived at destination")
        ActiveCommuteStore.clear()
        routeStore.setBackgroundLocationUpdates(false)
        withAnimation(DesignTokens.Motion.morph) { arrivedAt = now }
    }
}
