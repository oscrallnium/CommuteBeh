//
//  DirectionsTransport.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/31/26.
//

import MapKit

/// Maps the graph's own transport hint (`TransitEdge.mkDirectionsTransportType`,
/// `TransportModeConfig.mkDirectionsTransportType`) to the MapKit type used when asking
/// MKDirections for real geometry.
///
/// Only `"walking"` is honoured directly. The other hint in the data is `"transit"`
/// (jeepney, bus), and it must **not** be passed through: MapKit has no jeepney or bus
/// coverage in the Philippines, so a `.transit` request returns nothing useful and can hang
/// until it times out. Those modes snap as `.automobile`, which follows the road network
/// they actually drive on.
enum DirectionsTransport {

    /// MapKit transport type for snapping an edge carrying `hint`.
    static func snapType(for hint: String?) -> MKDirectionsTransportType {
        hint == walkingHint ? .walking : .automobile
    }

    /// The one hint value that maps to pedestrian routing. Matches the JSON vocabulary —
    /// mode strings themselves are never hardcoded in Swift (see CLAUDE.md).
    static let walkingHint = "walking"
}
