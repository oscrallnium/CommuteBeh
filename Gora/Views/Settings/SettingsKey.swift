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
    static let use24HourTime = "use24HourTime"
    static let showOtherModes = "showOtherModes"
    static let excludedPayments = "excludedPayments"

    /// True when the passenger chose 24-hour time. The default is 12-hour time with AM/PM.
    static var uses24HourTime: Bool {
        UserDefaults.standard.bool(forKey: use24HourTime)
    }

    /// True unless the passenger turned Live Activities off.
    static var isLiveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: liveActivitiesEnabled) as? Bool ?? true
    }

    /// True unless usage data sharing was turned off. Analytics collection follows this value.
    static var isShareUsageDataEnabled: Bool {
        UserDefaults.standard.object(forKey: shareUsageData) as? Bool ?? true
    }

    /// True unless the passenger turned the near-destination vibration off.
    static var isVibrateNearDestinationEnabled: Bool {
        UserDefaults.standard.object(forKey: vibrateNearDestination) as? Bool ?? true
    }

    /// True unless the passenger turned the one-stop-before-exit vibration off.
    static var isVibrateStopBeforeExitEnabled: Bool {
        UserDefaults.standard.object(forKey: vibrateStopBeforeExit) as? Bool ?? true
    }

    /// Payment IDs the passenger turned off. Empty means every payment method is on.
    static var excludedPaymentIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: excludedPayments) ?? [])
    }

    /// Stores the payment IDs the passenger turned off, as a sorted array.
    static func setExcludedPaymentIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: excludedPayments)
    }
}
