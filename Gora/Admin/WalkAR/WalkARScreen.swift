//
//  WalkARScreen.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import ARKit
import SwiftUI

/// Full-screen AR guidance along a walk polyline.
struct WalkARScreen: View {
    @State private var viewModel: WalkARViewModel
    @Environment(\.dismiss) private var dismiss

    init(polyline: [Coordinates], surveyID: UUID? = nil) {
        _viewModel = State(initialValue: WalkARViewModel(polyline: polyline, surveyID: surveyID))
    }

    var body: some View {
        ZStack {
            if !ARWorldTrackingConfiguration.isSupported {
                unsupportedNotice
            } else if viewModel.survey?.phase == .loading {
                ProgressView().tint(.white)
            } else {
                WalkARSceneView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .opacity(viewModel.tier.showsCameraContent ? 1 : 0)
                    .animation(.easeInOut(duration: WalkARGuidanceScene.crossfadeSeconds), value: viewModel.tier)
            }
            WalkARScreenChevronLayer(viewModel: viewModel)
            WalkARHUD(state: viewModel.hud, surveyStatus: viewModel.survey?.statusLine,
                      tier: viewModel.tier, tierReason: viewModel.tierReason, surveyState: viewModel.surveyState,
                      survey: viewModel.survey?.metadata,
                      hidesWarning: viewModel.showsCenterGuide, onClose: { dismiss() })
        }
        .background(Color.black)
        .task { await viewModel.loadSurvey() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.stop()
        }
    }

    private var unsupportedNotice: some View {
        Text("AR is not available on this device.")
            .font(DesignTokens.TypeScale.instruction)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(DesignTokens.Space.l)
    }
}
