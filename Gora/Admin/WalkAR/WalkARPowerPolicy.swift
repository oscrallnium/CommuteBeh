//
//  WalkARPowerPolicy.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import ARKit

/// How much work Walk AR may do. A higher value means less work.
nonisolated enum WalkARPowerState: Int, Comparable {
    case full
    case reduced
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Reads the thermal state and Low Power Mode and publishes one `WalkARPowerState`.
final class WalkARPowerPolicy {
    private(set) var state = WalkARPowerState.full
    var onChange: ((WalkARPowerState) -> Void)?
    private var tasks: [Task<Void, Never>] = []

    /// Reads the state now and follows every later change.
    func start() {
        refresh()
        guard tasks.isEmpty else { return }
        let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        tasks = names.map { name in
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) { self?.refresh() }
            }
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// The 30 fps format with the largest image, or `nil` when the device lists none.
    static func thirtyFpsFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.framesPerSecond == 30 }
            .max { $0.imageResolution.width < $1.imageResolution.width }
    }

    static func state(thermal: ProcessInfo.ThermalState, isLowPower: Bool) -> WalkARPowerState {
        if thermal == .critical { return .critical }
        return thermal == .serious || isLowPower ? .reduced : .full
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let next = Self.state(thermal: info.thermalState, isLowPower: info.isLowPowerModeEnabled)
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
