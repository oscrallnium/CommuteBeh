//
//  WalkARLocationService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import CoreLocation

/// A compass reading with its error bar.
struct WalkARHeading: Sendable {
    /// Degrees clockwise from true north. Negative when the system cannot supply it.
    let trueDegrees: Double
    let accuracyDegrees: Double
}

/// GPS and compass feed for the walk AR test. It owns one `CLLocationManager`.
final class WalkARLocationService: NSObject, CLLocationManagerDelegate {

    var onFix: ((CLLocation) -> Void)?
    var onHeading: ((WalkARHeading) -> Void)?
    var onDenied: (() -> Void)?

    private let manager = CLLocationManager()
    private var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.headingFilter = 3
    }

    func start() {
        isRunning = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: beginUpdates()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: onDenied?()
        }
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        Task { @MainActor [weak self] in self?.onFix?(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = WalkARHeading(trueDegrees: newHeading.trueHeading, accuracyDegrees: newHeading.headingAccuracy)
        Task { @MainActor [weak self] in self?.onHeading?(heading) }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.beginUpdates()
            case .denied, .restricted: self.onDenied?()
            default: break
            }
        }
    }
}
