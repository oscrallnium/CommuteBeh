//
//  StationGrid.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/15/26.
//

import Foundation

/// A uniform lat/lng grid over a list of coordinates. A query returns every index whose
/// point can lie within the radius, so the caller still applies its own exact distance test.
nonisolated struct StationGrid {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private let cellKm: Double
    private let latDegrees: Double
    private let lngDegrees: Double
    private var cells: [Cell: [Int]] = [:]

    /// A cell is at least `cellKm` wide in both directions. The longitude width uses the
    /// highest latitude in the list, where a degree of longitude is shortest.
    init(coordinates: [Coordinates], cellKm: Double) {
        let kmPerLatDegree = 110.0
        let maxAbsLat = (coordinates.map { abs($0.lat) }.max() ?? 0) + 0.1
        let cosLat = max(cos(min(maxAbsLat, 89.9) * .pi / 180), 0.01)
        self.cellKm = cellKm
        latDegrees = cellKm / kmPerLatDegree
        lngDegrees = cellKm / (kmPerLatDegree * cosLat)
        for (index, coordinate) in coordinates.enumerated() {
            cells[cell(of: coordinate), default: []].append(index)
        }
    }

    /// Indices in ascending order from every cell within `radiusKm` of `coordinate`.
    func indices(near coordinate: Coordinates, radiusKm: Double) -> [Int] {
        let span = max(1, Int((radiusKm / cellKm).rounded(.up)))
        let center = cell(of: coordinate)
        var result: [Int] = []
        for dx in -span...span {
            for dy in -span...span {
                if let bucket = cells[Cell(x: center.x + dx, y: center.y + dy)] {
                    result.append(contentsOf: bucket)
                }
            }
        }
        result.sort()
        return result
    }

    private func cell(of coordinate: Coordinates) -> Cell {
        Cell(x: Self.bucket(coordinate.lng / lngDegrees), y: Self.bucket(coordinate.lat / latDegrees))
    }

    private static func bucket(_ value: Double) -> Int {
        value.isFinite && abs(value) < 1e15 ? Int(value.rounded(.down)) : 0
    }
}
