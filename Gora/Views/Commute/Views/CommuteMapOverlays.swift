//
//  CommuteMapOverlays.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Transfer Node

/// Canvas-filled dot with an ink ring, marking where a route changes leg.
struct TransferNode: View {
    var body: some View {
        Circle()
            .fill(Color.canvas)
            .frame(width: 5, height: 5)
            .padding(2.5)
            .background(Circle().fill(Color.onyx))
    }
}

// MARK: - Passenger Puck

/// Content for the passenger's `UserAnnotation`. MapKit owns the position; this supplies the
/// orange look and one behaviour — an idle breathe while the passenger stands still, which
/// stops as soon as `speed` reports movement.
struct PassengerPuck: View {
    /// `userLocation.location?.speed`, handed down by the `UserAnnotation` closure. `nil`
    /// before MapKit has a fix.
    let speed: CLLocationSpeed?

    @State private var isStill = true
    /// Debounced target for `isStill` — see the `.task(id:)` below. Kept separate so a
    /// single noisy sample crossing the threshold can't flip the pulse on its own.
    @State private var pendingStill = true
    @State private var breathe = false

    private static let haloSize: CGFloat = 32
    private static let dotSize: CGFloat = 14
    private static let ringWidth: CGFloat = 3

    /// Below this, the passenger reads as stopped rather than mid-stride — comfortably
    /// under even a slow walk (~1.2 m/s), so nothing anyone would call moving triggers it.
    private static let stillThreshold: CLLocationSpeed = 0.4
    /// How long a speed reading must hold before the pulse commits to it. Long enough that a
    /// sample hovering near the threshold does not flicker the halo on and off.
    private static let debounce = Duration.milliseconds(700)

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignTokens.Colors.positionHalo)
                .frame(width: Self.haloSize, height: Self.haloSize)
                .scaleEffect(isStill && breathe ? 1.25 : 1.0)
            Circle()
                .fill(Color.tangerine)
                .frame(width: Self.dotSize, height: Self.dotSize)
            Circle()
                .stroke(Color.canvas, lineWidth: Self.ringWidth)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
        .onChange(of: speed, initial: true) { _, newSpeed in
            pendingStill = Self.isBelowThreshold(newSpeed)
        }
        // Auto-cancelled and restarted by SwiftUI on every `pendingStill` change, which is
        // what makes this a debounce rather than a delay: a classification that flips back
        // before `debounce` elapses just restarts the wait instead of committing.
        .task(id: pendingStill) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isStill = pendingStill
        }
        .onChange(of: isStill, initial: true) { _, still in
            if still {
                withAnimation(DesignTokens.Motion.locationPulse) { breathe = true }
            } else {
                // A plain assignment, not `withAnimation`. `isStill` already masks `breathe`,
                // so the halo is at rest and this only resets the value for the next animation.
                breathe = false
            }
        }
    }

    private static func isBelowThreshold(_ speed: CLLocationSpeed?) -> Bool {
        // No reliable reading — no fix yet, or CoreLocation's "invalid" sentinel — reads
        // as still. There's no evidence of movement to justify treating it otherwise.
        guard let speed, speed >= 0 else { return true }
        return speed < stillThreshold
    }
}

#if DEBUG
#Preview("Puck · light") {
    PassengerPuck(speed: 0)
        .frame(width: 120, height: 120)
        .background(Color(.systemGray4))
        .preferredColorScheme(.light)
}

#Preview("Puck · dark") {
    PassengerPuck(speed: 0)
        .frame(width: 120, height: 120)
        .background(Color(.systemGray4))
        .preferredColorScheme(.dark)
}
#endif
