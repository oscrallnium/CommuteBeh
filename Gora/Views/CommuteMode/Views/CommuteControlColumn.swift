//
//  CommuteControlColumn.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// The vertical map controls above the commute sheet. Apart, they are three glass circles.
/// Merged, the 2D/3D and Track circles melt into the ellipsis circle, whose menu holds all
/// five actions.
struct CommuteControlColumn: View {
    @Binding var cameraMode: CommuteCameraMode
    /// While true the follow loop rewrites the camera, so the map cannot be panned.
    @Binding var isFollowing: Bool
    let isMerged: Bool
    let onRouteOverview: () -> Void
    let onTripDetails: () -> Void
    let onEndCommute: () -> Void

    @Namespace private var glassNS

    private let circleSize: CGFloat = 52

    var body: some View {
        GlassEffectContainer(spacing: DesignTokens.Space.sm) {
            VStack(spacing: DesignTokens.Space.sm) {
                if !isMerged {
                    cameraButton.glassEffectID("camera", in: glassNS)
                    trackButton.glassEffectID("track", in: glassNS)
                }
                moreMenu.glassEffectID("more", in: glassNS)
            }
        }
    }

    // MARK: Circles

    /// Shows the mode a tap switches to.
    private var cameraButton: some View {
        Button(action: toggleCamera) {
            Text(cameraMode == .twoD ? "3D" : "2D")
                .font(DesignTokens.TypeScale.rowTitleCurrent)
                .foregroundStyle(.primary)
                .frame(width: circleSize, height: circleSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(cameraMode == .twoD ? "Switch to 3D" : "Switch to 2D")
    }

    private var trackButton: some View {
        Button(action: toggleTracking) {
            Image(systemName: isFollowing ? "location.fill" : "location")
                .font(.title3)
                .foregroundStyle(Color.ember)
                .frame(width: circleSize, height: circleSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(isFollowing ? "Stop following your location" : "Follow your location")
    }

    private var moreMenu: some View {
        Menu {
            if isMerged {
                Section {
                    Button(action: toggleCamera) {
                        Label(cameraMode == .twoD ? "3D View" : "2D View", systemImage: "view.3d")
                    }
                    Button(action: toggleTracking) {
                        Label(isFollowing ? "Untrack" : "Track",
                              systemImage: isFollowing ? "location.slash" : "location")
                    }
                }
            }
            Section {
                Button(action: onRouteOverview) {
                    Label("Route Overview", systemImage: "map")
                }
                Button(action: onTripDetails) {
                    Label("Trip Details", systemImage: "list.bullet")
                }
                Button(role: .destructive, action: onEndCommute) {
                    Label("End Commute", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: circleSize, height: circleSize)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel("More")
    }

    // MARK: Actions

    private func toggleCamera() {
        cameraMode = cameraMode == .twoD ? .threeD : .twoD
    }

    private func toggleTracking() {
        isFollowing.toggle()
    }
}

#if DEBUG
/// Both states of the column, with a button that merges and splits it.
private struct CommuteControlColumnPreview: View {
    @State var isMerged: Bool
    @State private var cameraMode = CommuteCameraMode.twoD
    @State private var isFollowing = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGray4).ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 24) {
                Button(isMerged ? "Separate" : "Merge") {
                    withAnimation(DesignTokens.Motion.controlMorph) { isMerged.toggle() }
                }
                .buttonStyle(.borderedProminent)
                CommuteControlColumn(
                    cameraMode: $cameraMode, isFollowing: $isFollowing, isMerged: isMerged,
                    onRouteOverview: {}, onTripDetails: {}, onEndCommute: {})
            }
            .padding(DesignTokens.Space.l)
        }
    }
}

#Preview("Separate · light") {
    CommuteControlColumnPreview(isMerged: false).preferredColorScheme(.light)
}

#Preview("Separate · dark") {
    CommuteControlColumnPreview(isMerged: false).preferredColorScheme(.dark)
}

#Preview("Merged · light") {
    CommuteControlColumnPreview(isMerged: true).preferredColorScheme(.light)
}

#Preview("Merged · dark") {
    CommuteControlColumnPreview(isMerged: true).preferredColorScheme(.dark)
}
#endif
