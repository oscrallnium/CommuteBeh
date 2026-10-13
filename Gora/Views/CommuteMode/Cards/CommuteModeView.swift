//
//  CommuteModeView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import SwiftUI
import CoreLocation

/// Two fixed camera poses for Commute Mode's map. `twoD` is flat and north-up. `threeD` is
/// tilted and turns to the route direction, so the camera sits behind the passenger.
/// `puckFraction` is the puck's height in the visible map strip, measured from the strip top.
enum CommuteCameraMode {
    case twoD
    case threeD

    var pitch: Double { self == .threeD ? 50 : 0 }
    var distance: CLLocationDistance { self == .threeD ? 300 : 800 }
    var puckFraction: CGFloat { self == .threeD ? 0.7 : 0.5 }
}

/// Reads the live engine and route store, and feeds the commute sheet card. The sheet content
/// closure never reads engine values itself, so this view re-evaluates when they change.
struct CommuteModeView: View {
    let result: RouteResult
    let engine: CommuteProgressEngine
    let routeStore: RouteStore
    /// What the passenger typed or selected, which can differ from `result.legs.last?.toStation`.
    let destinationText: String
    /// Non-nil once the passenger reached the destination.
    let arrivedAt: Date?
    @Binding var cardState: CommuteCardState
    @Binding var showEndAlert: Bool
    let onEndCommute: () -> Void

    var body: some View {
        CommuteSheetCard(model: model, cardState: $cardState, showEndAlert: $showEndAlert,
                         onEndCommute: onEndCommute)
    }

    private var model: CommuteSheetModel {
        let summary = RouteCardSummary(result: result)
        return CommuteSheetModel(
            destination: destinationText,
            remainingText: RouteCardSummary.distanceLabel(remainingMeters / 1000),
            speedText: speedText,
            isRerouting: routeStore.isRerouting,
            arrivalTime: summary.arrivalTime,
            rows: result.legs.map { CommuteLegRowModel(leg: $0, lineName: routeStore.lineDisplayName, legColor: routeStore.legColor) },
            currentLegIndex: engine.currentLegIndex,
            arrivedAt: arrivedAt
        )
    }

    /// Metres left on the current leg plus the planned length of every later leg.
    private var remainingMeters: CLLocationDistance {
        let ahead = result.legs.dropFirst(engine.currentLegIndex + 1).reduce(0) { $0 + $1.distanceKm * 1000 }
        return engine.metersRemainingOnCurrentLeg + ahead
    }

    private var speedText: String? {
        guard let speed = routeStore.userSpeed, speed >= 0 else { return nil }
        return "\(Int((speed * 3.6).rounded())) km/h"
    }
}
