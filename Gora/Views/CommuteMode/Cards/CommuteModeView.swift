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

    var pitch: Double { self == .threeD ? 60 : 0 }
    /// Metres from the camera to the map center. Commute Mode opens in 2D at this distance.
    var distance: CLLocationDistance { self == .threeD ? 450 : 2500 }
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
    /// Runs when the rider taps "I've Arrived" on the last step with Location off.
    let onArrive: () -> Void
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false

    /// The model and the planned time left are read here, so this view re-evaluates when they change.
    /// The timeline then moves the estimated arrival forward each minute.
    var body: some View {
        let base = model
        let secondsLeft = engine.plannedSecondsRemaining
        TimelineView(.everyMinute) { context in
            CommuteSheetCard(model: estimated(base, at: context.date, secondsLeft: secondsLeft),
                             cardState: $cardState, showEndAlert: $showEndAlert,
                             onEndCommute: onEndCommute, onSelectStep: selectStep)
        }
    }

    /// The arrival is `now` plus the planned time left from the current step.
    /// The Live Activity uses the same rule, so both show the same time.
    private func estimated(_ base: CommuteSheetModel, at now: Date, secondsLeft: Double) -> CommuteSheetModel {
        var estimate = base
        let parts = RouteCardSummary.clockParts(now.addingTimeInterval(secondsLeft), uses24HourTime: use24HourTime)
        estimate.arrivalTime = parts.time
        estimate.arrivalPeriod = parts.period
        return estimate
    }

    /// A step past the last one is the arrival.
    private func selectStep(_ index: Int) {
        guard index < result.legs.count else {
            onArrive()
            return
        }
        withAnimation(DesignTokens.Motion.locationState) { engine.setCurrentLeg(index) }
    }

    private var model: CommuteSheetModel {
        let summary = RouteCardSummary(result: result, uses24HourTime: use24HourTime)
        return CommuteSheetModel(
            destination: destinationText,
            remainingText: RouteCardSummary.distanceLabel(remainingMeters / 1000),
            speedText: speedText,
            isRerouting: routeStore.isRerouting,
            arrivalTime: summary.arrivalTime,
            arrivalPeriod: summary.arrivalPeriod,
            rows: result.legs.map { CommuteLegRowModel(leg: $0, lineName: routeStore.lineDisplayName, legColor: routeStore.legColor) },
            currentLegIndex: engine.currentLegIndex,
            arrivedAt: arrivedAt,
            manualStep: manualStep
        )
    }

    private var manualStep: CommuteManualStep? {
        guard routeStore.locationAccess == .off else { return nil }
        return CommuteManualStep(legs: result.legs, index: engine.currentLegIndex,
                                 lineName: routeStore.lineDisplayName, legColor: routeStore.legColor)
    }

    private var remainingMeters: CLLocationDistance { engine.metersRemainingToDestination }

    private var speedText: String? {
        guard let speed = routeStore.userSpeed, speed >= 0 else { return nil }
        return "\(Int((speed * 3.6).rounded())) km/h"
    }
}
