//
//  SavedPlacesStore.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation

/// The passenger's saved places, cached in `Application Support/SavedPlaces/saved_places.json`.
/// File reads and writes run off the main actor; writes run in the order they are requested.
@Observable
@MainActor
final class SavedPlacesStore {
    private(set) var places: [SavedPlace] = []

    private let fileURL: URL
    private var writeTask: Task<Void, Never>?

    init(fileURL: URL = SavedPlacesStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "SavedPlaces", directoryHint: .isDirectory)
            .appending(path: "saved_places.json", directoryHint: .notDirectory)
    }

    func load() async {
        let url = fileURL
        places = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
    }

    func add(_ place: SavedPlace) {
        places.append(place)
        persist()
    }

    /// Replaces the stored place that has the same `id`. The order does not change.
    func update(_ place: SavedPlace) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index] = place
        persist()
    }

    func remove(id: SavedPlace.ID) {
        places.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let snapshot = places
        let url = fileURL
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            Self.write(snapshot, to: url)
        }
    }

    nonisolated private static func read(_ url: URL) -> [SavedPlace] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? ARSurveyCoding.makeDecoder().decode([SavedPlace].self, from: data)) ?? []
    }

    nonisolated private static func write(_ places: [SavedPlace], to url: URL) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? ARSurveyCoding.makeEncoder().encode(places) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
