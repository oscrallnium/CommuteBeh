//
//  ArrivalAlerts.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import CoreLocation
import UIKit
import UserNotifications

extension CommuteProgressEngine {
    /// Metres left on the current leg plus the planned length of every later leg.
    var metersRemainingToDestination: CLLocationDistance {
        let ahead = result.legs.dropFirst(currentLegIndex + 1).reduce(0) { $0 + $1.distanceKm * 1000 }
        return metersRemainingOnCurrentLeg + ahead
    }
}

/// Vibrates the phone near the destination and one stop before a train exit. Each alert fires
/// once per commute. See `CommuteMode-State.md`.
@MainActor
final class ArrivalAlerts {
    static let shared = ArrivalAlerts()

    static let nearDestinationMeters: CLLocationDistance = 200

    private static let nearDestinationID = "arrival.nearDestination"
    private static let stopBeforeExitID = "arrival.stopBeforeExit"
    private static let secondPulseDelay: Duration = .milliseconds(400)

    private var hasSeenFarFromDestination = false
    private var hasFiredNearDestination = false
    private var firedExitLegIndexes: Set<Int> = []

    /// Clears the fired flags. Call when a commute starts or ends.
    func reset() {
        hasSeenFarFromDestination = false
        hasFiredNearDestination = false
        firedExitLegIndexes = []
    }

    /// Checks both alerts against the latest progress. Call on every progress tick.
    func update(engine: CommuteProgressEngine, destinationName: String) {
        checkNearDestination(engine: engine, destinationName: destinationName)
        checkStopBeforeExit(engine: engine)
    }

    // MARK: Triggers

    /// Fires when the distance left first drops to the threshold after the passenger was farther away.
    private func checkNearDestination(engine: CommuteProgressEngine, destinationName: String) {
        guard !hasFiredNearDestination else { return }
        let remaining = engine.metersRemainingToDestination
        guard remaining <= Self.nearDestinationMeters else {
            hasSeenFarFromDestination = true
            return
        }
        guard hasSeenFarFromDestination else { return }
        hasFiredNearDestination = true
        guard SettingsKey.isVibrateNearDestinationEnabled else { return }
        vibrate(id: Self.nearDestinationID, title: "Almost there",
                body: "You are about \(Int(Self.nearDestinationMeters)) m from \(destinationName).")
    }

    /// Fires on a train leg once the passenger is past the leg's second-to-last stop.
    private func checkStopBeforeExit(engine: CommuteProgressEngine) {
        let index = engine.currentLegIndex
        guard engine.result.legs.indices.contains(index), !firedExitLegIndexes.contains(index) else { return }
        let leg = engine.result.legs[index]
        guard leg.mode == .train, let metersFromPreviousStop = Self.metersFromPreviousStopToExit(of: leg),
              engine.metersRemainingOnCurrentLeg <= metersFromPreviousStop else { return }
        firedExitLegIndexes.insert(index)
        guard SettingsKey.isVibrateStopBeforeExitEnabled else { return }
        vibrate(id: Self.stopBeforeExitID, title: "Next stop: \(leg.toStation.name)",
                body: "Get ready to get off at \(leg.toStation.name).")
    }

    /// Distance along the leg polyline from the second-to-last stop to the exit station.
    /// Nil when the leg has no stop before the exit.
    private static func metersFromPreviousStopToExit(of leg: RouteLeg) -> CLLocationDistance? {
        guard leg.stops.count >= 3 else { return nil }
        let previous = leg.stops[leg.stops.count - 2].coordinates
        let points = leg.polylineCoordinates
        guard points.count >= 2 else { return previous.distance(to: leg.toStation.coordinates) }
        let nearest = points.indices.min { previous.distance(to: points[$0]) < previous.distance(to: points[$1]) } ?? 0
        return points.indices.dropFirst(nearest + 1).reduce(0) { $0 + points[$1 - 1].distance(to: points[$1]) }
    }

    // MARK: Delivery

    /// Plays haptics while the app is active, and posts a local notification otherwise.
    private func vibrate(id: String, title: String, body: String) {
        if UIApplication.shared.applicationState == .active {
            Task { await playHaptic() }
        } else {
            Task { await postNotification(id: id, title: title, body: body) }
        }
    }

    private func playHaptic() async {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        try? await Task.sleep(for: Self.secondPulseDelay)
        generator.notificationOccurred(.warning)
    }

    /// Posts at once. The default sound makes the phone vibrate. Does nothing without permission.
    private func postNotification(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

private extension Coordinates {
    func distance(to other: Coordinates) -> CLLocationDistance {
        CLLocation(latitude: lat, longitude: lng).distance(from: CLLocation(latitude: other.lat, longitude: other.lng))
    }
}
