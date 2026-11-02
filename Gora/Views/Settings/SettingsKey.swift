//
//  SettingsKey.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import Foundation

/// Storage keys of the Settings screen. Code outside the screen reads a setting through these keys.
enum SettingsKey {
    static let routePreference = "routePreference"
    static let fareDiscount = "fareDiscount"
    static let liveActivitiesEnabled = "liveActivitiesEnabled"
    static let saveTripHistory = "saveTripHistory"
    static let shareUsageData = "shareUsageData"
    static let vibrateNearDestination = "vibrateNearDestination"
    static let vibrateStopBeforeExit = "vibrateStopBeforeExit"
    static let liquidGlassEnabled = "liquidGlassEnabled"

    /// True unless the passenger turned Live Activities off.
    static var isLiveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: liveActivitiesEnabled) as? Bool ?? true
    }

    /// True unless the passenger turned the near-destination vibration off.
    static var isVibrateNearDestinationEnabled: Bool {
        UserDefaults.standard.object(forKey: vibrateNearDestination) as? Bool ?? true
    }

    /// True unless the passenger turned the one-stop-before-exit vibration off.
    static var isVibrateStopBeforeExitEnabled: Bool {
        UserDefaults.standard.object(forKey: vibrateStopBeforeExit) as? Bool ?? true
    }
}
