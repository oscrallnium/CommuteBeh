//
//  CommuteModeView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/9/26.
//

import SwiftUI
import CoreLocation

/// Two fixed camera poses for Commute Mode's map — not a continuous pitch slider.
/// `pitch: 0` is what every other `MapCamera` in this codebase already uses (there is
/// no other 2D/3D precedent to match); `threeD` is simply closer and tilted. Neither
/// mode follows the passenger's heading — `RouteStore.userLocation` carries no course,
/// so a heading-aligned 3D camera (the Apple Maps convention) is future work.
enum CommuteCameraMode {
    case twoD
    case threeD

    var pitch: Double { self == .threeD ? 60 : 0 }
    var distance: CLLocationDistance { self == .threeD ? 300 : 800 }
}

/// The bottom card shown once a route has been committed to. Compact state is a single
/// live-status row; "See route" expands it to the full leg list via `CommuteLegList`.
/// The card's own shape carries the `matchedGeometryEffect` id `"commute-card"`, matched
/// against the selected `RouteOptionCard`'s shape in `ContentView` — this is what makes
/// entering Commute Mode read as the search card morphing into this one.
struct CommuteModeView: View {
    let result: RouteResult
    let engine: CommuteProgressEngine
    /// What the passenger actually typed/selected — not `result.legs.last?.toStation`,
    /// which can be an internal station name that doesn't match what they searched for.
    let destinationText: String
    let morphNS: Namespace.ID
    @Binding var cameraMode: CommuteCameraMode
    let onEndCommute: () -> Void

    @State private var isExpanded = false

    private var summary: RouteCardSummary { RouteCardSummary(result: result) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isExpanded {
                expandedHeader
                CommuteLegList(legRows: summary.legRows,
                               currentLegIndex: engine.currentLegIndex,
                               metersRemainingOnCurrentLeg: engine.metersRemainingOnCurrentLeg)
                Divider()
            } else {
                currentLegRow
            }
            summaryRow
            endCommuteButton
        }
        .padding(18)
        .background(DesignTokens.Colors.paper)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cardShadow(y: -4)
        .matchedGeometryEffect(id: "commute-card", in: morphNS)
        .overlay(alignment: .topTrailing) {
            if !isExpanded {
                cameraToggleButton.padding(12)
            }
        }
    }

    // MARK: Compact state

    private var currentLegRow: some View {
        HStack(alignment: .top, spacing: 12) {
            currentLegIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(currentLeg?.instruction ?? "")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Text("\(RouteCardSummary.distanceLabel(engine.metersRemainingOnCurrentLeg / 1000)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            seeRouteToggle
        }
        // The 2D/3D toggle floats as a card-level overlay in this same top-right
        // corner (only in compact state, which is exactly when this row is showing) —
        // without this, "See route" runs directly under it.
        .padding(.trailing, 40)
    }

    @ViewBuilder
    private var currentLegIcon: some View {
        let mode = currentLeg?.mode ?? .walk
        let isWalk = currentLeg?.mode == .walk || currentLeg?.line == "INTERCHANGE"
        ZStack {
            if isWalk {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: TransportMode.walk.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(mode.color.opacity(0.15))
                Image(systemName: mode.icon)
                    .font(.caption)
                    .foregroundStyle(mode.color)
            }
        }
        .frame(width: 36, height: 36)
    }

    private var currentLeg: RouteLeg? {
        result.legs.indices.contains(engine.currentLegIndex) ? result.legs[engine.currentLegIndex] : nil
    }

    // MARK: Expanded state

    private var expandedHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("RIGHT NOW · LEG \(engine.currentLegIndex + 1) OF \(result.legs.count)")
                    .font(.caption2.weight(.heavy))
                    .kerning(0.4)
                    .foregroundStyle(DesignTokens.Colors.success)
                Text(currentLeg?.instruction ?? "")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            seeRouteToggle
        }
    }

    // MARK: Shared

    /// "See route" ⇄ "Hide" — same mechanical reel-drop `ReelSwap` already used for
    /// "See route details" ⇄ "Hide route details" on the search-results card.
    private var seeRouteToggle: some View {
        Button {
            withAnimation(DesignTokens.Motion.disclose) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                ReelSwap(isAlternate: isExpanded, distance: 14) {
                    Text("See route").font(.caption.weight(.semibold))
                } alternate: {
                    Text("Hide").font(.caption.weight(.semibold))
                }
                ReelSwap(isAlternate: isExpanded, distance: 12) {
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                } alternate: {
                    Image(systemName: "chevron.up").font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(Color.charcoal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(destinationText)
                .font(.headline)
                .lineLimit(1)
            Text(isExpanded ? "\(summary.arriveText) · ₱\(summary.fareText) total" : summary.arriveText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            onTimeIndicator
        }
    }

    private var onTimeIndicator: some View {
        let isOnTime = engine.onTimeStatus == .onTime
        return HStack(spacing: 4) {
            Circle()
                .fill(isOnTime ? DesignTokens.Colors.success : DesignTokens.Colors.warning)
                .frame(width: 6, height: 6)
            Text(isOnTime ? "On time" : "Delayed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOnTime ? DesignTokens.Colors.success : DesignTokens.Colors.warning)
        }
        .fixedSize()
    }

    private var endCommuteButton: some View {
        Button(action: onEndCommute) {
            Text("End commute")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Shows the mode tapping switches *to* — Apple Maps' own convention for this
    /// control, and why it reads "3D" while the map is actually in 2D.
    private var cameraToggleButton: some View {
        Button {
            cameraMode = cameraMode == .twoD ? .threeD : .twoD
        } label: {
            Text(cameraMode == .twoD ? "3D" : "2D")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.charcoal)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignTokens.Colors.paper))
                .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 1))
                .cardShadow()
        }
        .buttonStyle(.plain)
    }
}
