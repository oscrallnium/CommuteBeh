//
//  WalkARHUD.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// Screen-space overlay for the walk AR screen.
struct WalkARHUD: View {
    let state: WalkARHUDState
    var surveyStatus: String?
    var tier = GuidanceTier.t1Precise
    var tierReason = TierReason.aligned
    var surveyState: SurveyState?
    var survey: ARSurveyMetadata?
    var hidesWarning = false
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Space.s) {
            instructionCard
            if let warning = state.warning, !hidesWarning { warningBanner(warning) }
            if let surveyStatus { surveyBanner(surveyStatus) }
            if let tierCue { surveyBanner(tierCue).transition(.opacity) }
            if showsCoaching { WalkARCoachingCard(survey: survey).transition(.opacity) }
            Spacer()
            statusCard
        }
        .animation(.easeInOut(duration: WalkARGuidanceScene.crossfadeSeconds), value: tierCue)
        .animation(.easeInOut(duration: WalkARGuidanceScene.crossfadeSeconds), value: showsCoaching)
        .padding(DesignTokens.Space.l)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var instructionCard: some View {
        Text(state.instruction)
            .font(DesignTokens.TypeScale.instruction)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(DesignTokens.Space.m)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .padding(.trailing, 44)
    }

    /// A text cue for T3.
    private var tierCue: String? {
        tier == .t3NonAR ? "You can lower your phone." : nil
    }

    /// The coaching card shows in T4 and when the survey did not relocalize in time.
    private var showsCoaching: Bool {
        tier == .t4Recovery || surveyState == .timedOut
    }

    private func warningBanner(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeScale.subtitleEmphasis)
            .foregroundStyle(Color.licorice)
            .multilineTextAlignment(.center)
            .padding(DesignTokens.Space.sm)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.Colors.action, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func surveyBanner(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeScale.subtitleEmphasis)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(DesignTokens.Space.sm)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            statusRow("Distance left", Self.format(meters: state.metersLeft))
            statusRow("Direction match", "\(Int((state.yawConfidence * 100).rounded())) %")
            statusRow("GPS accuracy", state.gpsAccuracy.map { "\(Int($0.rounded())) m" } ?? "No fix")
            statusRow("Tracking", state.tracking.label)
            statusRow("Guidance", "T\(tier.rawValue + 1) · \(tierReason.label)")
        }
        .padding(DesignTokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value).foregroundStyle(.white)
        }
        .font(DesignTokens.TypeScale.subtitleEmphasis)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.65))
        }
        .padding(DesignTokens.Space.l)
        .accessibilityLabel("Close")
    }

    static func format(meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters.rounded())) m"
    }
}
