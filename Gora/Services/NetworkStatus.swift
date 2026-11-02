//
//  NetworkStatus.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import Network

/// Tracks whether the device has a usable network path. `isOnline` stays `true` until the
/// first path arrives, and `onChange` runs only when the value flips.
@MainActor
final class NetworkStatus {
    private(set) var isOnline = true
    var onChange: (() -> Void)?
    private var monitorTask: Task<Void, Never>?

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard let self else { return }
                self.apply(online: path.status == .satisfied)
            }
        }
    }

    private func apply(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?()
    }
}
