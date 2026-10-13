//
//  CommuteLiveActivityController.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import ActivityKit
import Foundation

/// Owns the one commute Live Activity: start, throttled update, end. See `LiveActivity.md`.
@MainActor
final class CommuteLiveActivityController {
    static let shared = CommuteLiveActivityController()

    typealias Snapshot = CommuteActivitySnapshot

    private var activity: Activity<CommuteActivityAttributes>?
    /// True from `start` until the next end call, including while the system request is in flight.
    private var isRunning = false
    private var destinationName = ""
    private var lineName: (String) -> String = { $0 }
    private var lastSent: Snapshot.State?
    private var lastSentAt: Date?
    private var lastFixAt = Date.now
    /// Serialises start and end so a late `end` never runs before its `request`.
    private var pending: Task<Void, Never>?

    private init() {}

    /// Records the time of the newest real GPS fix.
    func noteFix(at date: Date) {
        lastFixAt = date
    }

    func start(result: RouteResult, engine: CommuteProgressEngine, destinationName: String,
               now: Date, lineName: @escaping (String) -> String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        isRunning = true
        self.destinationName = destinationName
        self.lineName = lineName
        lastFixAt = now
        let attributes = Snapshot.attributes(result: result, destinationName: destinationName)
        let state = Snapshot.state(result: result, engine: engine, destinationName: destinationName,
                                   lastFixAt: now, now: now, lineName: lineName)
        let previous = pending
        pending = Task {
            await previous?.value
            await endAll(.immediate)
            activity = try? Activity.request(attributes: attributes, content: content(state), pushType: nil)
            lastSent = state
            lastSentAt = now
        }
    }

    /// Adopts the activity an earlier app run left and ends any extra ones. Starts a new activity
    /// when none is active. The next `update` sends fresh content.
    func reattach(result: RouteResult, engine: CommuteProgressEngine, destinationName: String,
                  startedAt: Date, lineName: @escaping (String) -> String) {
        let existing = Activity<CommuteActivityAttributes>.activities.filter { $0.activityState == .active }
        guard let adopted = existing.first else {
            return start(result: result, engine: engine, destinationName: destinationName,
                         now: startedAt, lineName: lineName)
        }
        isRunning = true
        activity = adopted
        self.destinationName = destinationName
        self.lineName = lineName
        lastFixAt = .now
        lastSent = nil
        lastSentAt = nil
        Task { for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) } }
    }

    func update(engine: CommuteProgressEngine, now: Date) {
        guard activity != nil else { return }
        let state = Snapshot.state(result: engine.result, engine: engine, destinationName: destinationName,
                                   lastFixAt: lastFixAt, now: now, lineName: lineName)
        guard Snapshot.shouldSend(state, last: lastSent, lastSentAt: lastSentAt, now: now) else { return }
        lastSent = state
        lastSentAt = now
        let target = activity
        Task { await target?.update(content(state)) }
    }

    /// Ends the activity on the arrived state and keeps it on screen for two minutes.
    func endArrived(now: Date) {
        guard let last = lastSent else { return end() }
        isRunning = false
        let final = Snapshot.arrivedState(from: last, destinationName: destinationName, now: now)
        let target = activity
        activity = nil
        lastSent = nil
        Task { await target?.end(ActivityContent(state: final, staleDate: nil),
                                 dismissalPolicy: .after(now.addingTimeInterval(120))) }
    }

    /// Removes the activity at once. Does nothing when no activity runs.
    func end() {
        guard isRunning else { return }
        isRunning = false
        let previous = pending
        activity = nil
        lastSent = nil
        pending = Task {
            await previous?.value
            await endAll(.immediate)
            activity = nil
        }
    }

    /// Ends every activity that an earlier app run left behind.
    func endOrphans() async {
        await endAll(.immediate)
    }

    private func endAll(_ policy: ActivityUIDismissalPolicy) async {
        for running in Activity<CommuteActivityAttributes>.activities {
            await running.end(nil, dismissalPolicy: policy)
        }
    }

    private func content(_ state: Snapshot.State) -> ActivityContent<Snapshot.State> {
        ActivityContent(state: state, staleDate: state.lastFixAt.addingTimeInterval(Snapshot.staleAfterSeconds))
    }
}
