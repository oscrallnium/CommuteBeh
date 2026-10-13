//
//  ActiveCommuteStore.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import Foundation

/// The commute data that survives app termination.
struct SavedCommute: Codable {
    let result: RouteResult
    let startedAt: Date
    let originText: String
    let destinationText: String
    let savedAt: Date

    /// Seconds after the planned trip time during which a saved commute still counts as active.
    private static let graceSeconds: TimeInterval = 3600

    /// True while `now` is before the planned end of the trip plus the grace period.
    func isRestorable(at now: Date) -> Bool {
        now < startedAt.addingTimeInterval(result.totalTimeMinutes * 60 + Self.graceSeconds)
    }
}

/// Reads and writes the one saved commute as a JSON file in Application Support.
/// See `CommuteMode-State.md`.
enum ActiveCommuteStore {

    private static var fileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("active_commute.json")
    }

    static func save(_ commute: SavedCommute) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(commute) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> SavedCommute? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedCommute.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
