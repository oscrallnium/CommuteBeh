//
//  SettingsPermissions.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import CoreLocation
import UserNotifications

/// The current location and notification access, shown as text on the Settings screen.
@Observable
@MainActor
final class SettingsPermissions {
    private(set) var locationValue = ""
    private(set) var notificationsValue = ""

    func refresh() async {
        locationValue = Self.locationText(CLLocationManager().authorizationStatus)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsValue = Self.isAllowed(settings.authorizationStatus) ? "On" : "Off"
    }

    /// Asks for notification access once, when the passenger has not answered yet.
    static func requestNotificationAccessIfUndetermined() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private static func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    private static func locationText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedWhenInUse: "While Using"
        case .authorizedAlways: "Always"
        case .denied, .restricted: "Never"
        default: "Ask Next Time"
        }
    }
}
