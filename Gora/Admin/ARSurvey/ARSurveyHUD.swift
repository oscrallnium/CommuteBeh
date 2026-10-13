//
//  ARSurveyHUD.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI
import ARKit

// MARK: - Plain-word status

extension ARFrame.WorldMappingStatus {
    /// The value of `world_mapping_quality` in the upload metadata.
    var apiName: String {
        switch self {
        case .notAvailable: "not_available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "not_available"
        }
    }

    var displayName: String {
        switch self {
        case .notAvailable: "Not available"
        case .limited: "Limited"
        case .extending: "Extending"
        case .mapped: "Mapped"
        @unknown default: "Unknown"
        }
    }
}

extension ARCamera.TrackingState {
    var displayName: String {
        switch self {
        case .normal: "Tracking is good"
        case .notAvailable: "Tracking is not available"
        case .limited(let reason):
            switch reason {
            case .initializing: "Starting up"
            case .excessiveMotion: "Moving too fast"
            case .insufficientFeatures: "Not enough detail in view"
            case .relocalizing: "Finding your saved spot"
            @unknown default: "Tracking is limited"
            }
        }
    }
}

// MARK: - HUD

struct ARSurveyHUD: View {
    let vm: ARSurveyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            statusRow(title: "Map", value: vm.mappingStatus.displayName)
            statusRow(title: "Camera", value: vm.trackingState.displayName)
            statusRow(title: "Signs", value: "\(vm.signCount)")
            statusRow(title: "Images", value: "\(vm.imageAnchors.count)")
            ForEach(vm.imageAnchors) { anchor in
                Text(anchor.name)
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let seconds = vm.relocalizationSeconds {
                statusRow(title: "Found in", value: seconds.formatted(.number.precision(.fractionLength(1))) + " s")
            }
        }
        .font(DesignTokens.TypeScale.subtitleEmphasis)
        .padding(DesignTokens.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func statusRow(title: String, value: String) -> some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

// MARK: - Placement

/// The hint line and the grey ring that show when no surface is under the screen centre.
struct ARSurveyPlacementHint: View {
    let quality: ARPlacementQuality

    var body: some View {
        Text(text)
            .font(DesignTokens.TypeScale.subtitleEmphasis)
            .padding(DesignTokens.Space.m)
            .background(.regularMaterial, in: Capsule())
    }

    private var text: String {
        switch quality {
        case .detected: "Tap to place a sign"
        case .estimated: "Tap to place a sign. Hold steady for a better fit"
        case .none: "Move your iPhone to find a surface"
        }
    }
}

struct ARSurveyCenterRing: View {
    var body: some View {
        Circle()
            .stroke(Color.slate.opacity(0.8), lineWidth: 3)
            .frame(width: 56, height: 56)
            .allowsHitTesting(false)
    }
}

// MARK: - Sign image framing

/// The rectangle the user fits around a sign. It fills the same area that the crop reads.
struct ARSignFramingGuide: View {
    var body: some View {
        GeometryReader { proxy in
            let rect = ARSignFraming.rect(in: proxy.size)
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                .stroke(.white, lineWidth: 3)
                .shadow(radius: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Capture and cancel buttons under the framing guide.
struct ARSignImageCaptureBar: View {
    let isCapturing: Bool
    let onCapture: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Space.m) {
            Text("Frame a permanent sign. Do not use an ad lightbox.")
                .font(DesignTokens.TypeScale.subtitleEmphasis)
                .multilineTextAlignment(.center)
            HStack(spacing: DesignTokens.Space.m) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button(isCapturing ? "Checking…" : "Capture", systemImage: "camera.fill", action: onCapture)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.action)
                    .foregroundStyle(Color.licorice)
                    .disabled(isCapturing)
            }
            .controlSize(.large)
        }
        .padding(DesignTokens.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

// MARK: - Coaching

struct ARSurveyCoachingCard: View {
    var body: some View {
        Label("Move your iPhone slowly around the area you scanned", systemImage: "iphone.gen3.radiowaves.left.and.right")
            .font(DesignTokens.TypeScale.controlLabel)
            .multilineTextAlignment(.center)
            .padding(DesignTokens.Space.l)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .padding(.horizontal, DesignTokens.Space.l)
    }
}
