//
//  ContentView+DebugSimulate.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/17/26.
//

#if DEBUG
import SwiftUI
import MapKit

// MARK: - Debug: simulated MRT ride
//
// A floating glass button that runs North Ave → Guadalupe in Commute Mode. It sits above the
// tab bar on the trailing side, or at the top trailing corner during a commute.
// The simulator owns `RouteStore.userLocation` for the whole run, so every consumer reads one position.
// Compiled out of release builds entirely. See `Debug.md`.

extension ContentView {

    @ViewBuilder
    var debugSimulateButton: some View {
        if !isCommuting || debugTrainSimulator.isActive {
            Button {
                Task { await toggleDebugSimulation() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: debugTrainSimulator.isActive ? "stop.fill" : "tram.fill")
                        .font(.system(size: 18))
                    Text(debugSimulateLabel)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.onyx)
                .padding(.leading, 15)
                .padding(.trailing, 18)
                .frame(height: 48)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(debugTrainSimulator.isStarting)
            .padding(.trailing, 16)
            .padding(.top, isCommuting ? 60 : 0)
            .padding(.bottom, isCommuting ? 0 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isCommuting ? .topTrailing : .bottomTrailing)
        }
    }

    private var debugSimulateLabel: String {
        if debugTrainSimulator.isActive { return "Stop Sim" }
        return debugTrainSimulator.lastError == nil ? "Simulate MRT" : "Sim failed"
    }

    /// Stops the active run through `endCommute(reason:)`, or starts a run when idle.
    func toggleDebugSimulation() async {
        if debugTrainSimulator.isActive {
            endCommute(reason: .debugStop)
            return
        }
        await debugTrainSimulator.start(routeStore: routeStore) { option in
            self.originText = option.result.legs.first?.fromStation.name ?? ""
            self.destinationText = option.result.legs.last?.toStation.name ?? ""
            self.startCommute(with: option)
            self.isFollowingPassenger = false
            await self.frameDebugSimStart()
        }
    }

    /// Frames the pre-run camera centre and the origin station, then locks onto the puck.
    private func frameDebugSimStart() async {
        await waitForPanelsToSettle()
        guard debugTrainSimulator.isActive else { return }
        frameDebugSimAnchorAndOrigin(anchor: debugSimAnchor)
        try? await Task.sleep(for: .seconds(DesignTokens.Motion.cameraFitDuration))
        guard debugTrainSimulator.isActive else { return }
        updateCommuteCamera(.start)
        try? await Task.sleep(for: .seconds(DesignTokens.Motion.cameraFitDuration))
        guard debugTrainSimulator.isActive else { return }
        isFollowingPassenger = true
    }

    /// Ends the run, returns the passenger position to real GPS, and frames the exit view.
    /// `recenterHome()` stays off until that framing move lands.
    func endDebugSimulationIfActive() {
        guard debugTrainSimulator.isActive else { return }
        let anchor = debugSimAnchor
        debugTrainSimulator.stop(routeStore: routeStore)
        debugSimHoldsCamera = true
        Task {
            await waitForPanelsToSettle()
            frameDebugSimAnchorAndOrigin(anchor: anchor)
            try? await Task.sleep(for: .seconds(DesignTokens.Motion.cameraFitDuration))
            debugSimHoldsCamera = false
        }
    }

    /// One camera move that shows the pre-run map centre and the origin station.
    private func frameDebugSimAnchorAndOrigin(anchor: CLLocationCoordinate2D?) {
        guard let origin = routeStore.allStations.first(where: { $0.id == DebugTrainSimulator.originStationID })
        else { return }
        let originPoint = CLLocationCoordinate2D(latitude: origin.coordinates.lat, longitude: origin.coordinates.lng)
        fitMap(bounds: RouteBounds(framing: anchor ?? Self.manilaRegion.center, originPoint))
    }
}

extension RouteBounds {
    init(framing a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) {
        minLat = min(a.latitude, b.latitude); maxLat = max(a.latitude, b.latitude)
        minLng = min(a.longitude, b.longitude); maxLng = max(a.longitude, b.longitude)
    }
}
#endif
