//
//  RoadSnapCache.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import CoreLocation
import MapKit

/// Disk cache of road-snapped edge polylines, kept in the Caches directory.
/// An entry is valid only while its fingerprint matches the edge's source geometry.
actor RoadSnapCache {

    static let shared = RoadSnapCache()

    nonisolated struct Entry: Codable, Sendable {
        let fingerprint: UInt64
        /// Interleaved latitude and longitude values.
        let values: [Double]

        init(fingerprint: UInt64, coordinates: [CLLocationCoordinate2D]) {
            self.fingerprint = fingerprint
            self.values = coordinates.flatMap { [$0.latitude, $0.longitude] }
        }

        var coordinates: [CLLocationCoordinate2D] {
            stride(from: 0, to: values.count - 1, by: 2).map {
                CLLocationCoordinate2D(latitude: values[$0], longitude: values[$0 + 1])
            }
        }
    }

    private nonisolated struct Payload: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    /// Increment when the fingerprint or the file layout changes.
    private static let formatVersion = 1

    private var loaded: [String: Entry]?

    /// Hashes the source coordinates and the transport type of one edge (FNV-1a, 64 bit).
    nonisolated static func fingerprint(
        coordinates: [CLLocationCoordinate2D],
        transportType: MKDirectionsTransportType
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                hash = (hash ^ ((value >> UInt64(shift)) & 0xff)) &* 0x100000001b3
            }
        }
        mix(UInt64(transportType.rawValue))
        for coordinate in coordinates {
            mix(coordinate.latitude.bitPattern)
            mix(coordinate.longitude.bitPattern)
        }
        return hash
    }

    /// Returns the cached polyline of each edge whose stored fingerprint matches.
    func snapped(matching fingerprints: [String: UInt64]) -> [String: [CLLocationCoordinate2D]] {
        let stored = entries()
        var hits: [String: [CLLocationCoordinate2D]] = [:]
        for (id, fingerprint) in fingerprints {
            guard let entry = stored[id], entry.fingerprint == fingerprint else { continue }
            let coordinates = entry.coordinates
            if coordinates.count >= 2 { hits[id] = coordinates }
        }
        return hits
    }

    /// Replaces the whole cache with the given entries, in one write.
    func replace(with newEntries: [String: Entry]) {
        loaded = newEntries
        guard let url = Self.fileURL() else { return }
        let payload = Payload(version: Self.formatVersion, entries: newEntries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func entries() -> [String: Entry] {
        if let loaded { return loaded }
        var result: [String: Entry] = [:]
        if let url = Self.fileURL(),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == Self.formatVersion {
            result = payload.entries
        }
        loaded = result
        return result
    }

    private nonisolated static func fileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("road_snap_cache.json")
    }
}
