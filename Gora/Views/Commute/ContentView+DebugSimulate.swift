//
//  ContentView+DebugSimulate.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/17/26.
//

#if DEBUG
import SwiftUI

// MARK: - Debug: simulated MRT ride
//
// A floating button that resolves North Ave → Guadalupe, runs the route, enters
// Commute Mode, and feeds `DebugTrainSimulator`'s synthetic fixes into the same
// `RouteStore.userLocation` real GPS writes to — so a full commute run is one tap
// instead of an actual train ride. Compiled out of release builds entirely.

extension ContentView {

    var debugSimulateButton: some View {
        Button {
            Task { await toggleDebugSimulation() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: debugTrainSimulator.isRunning ? "stop.fill" : "tram.fill")
                Text(debugTrainSimulator.isRunning ? "Stop Sim" : "Simulate MRT")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.top, 60)
        .padding(.trailing, 16)
    }

    /// Starts a run when idle, stops it (and leaves Commute Mode) when one is active.
    func toggleDebugSimulation() async {
        if debugTrainSimulator.isRunning {
            debugTrainSimulator.stop(routeStore: routeStore)
            endCommute()
            return
        }
        await debugTrainSimulator.start(routeStore: routeStore) { option in
            startCommute(with: option)
        }
    }
}
#endif
