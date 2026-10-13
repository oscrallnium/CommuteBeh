//
//  ARSurveyView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// The capture screen (new survey) and the replay screen (saved survey).
struct ARSurveyView: View {
    @State private var vm: ARSurveyViewModel

    init(route: ARSurveyRoute) {
        _vm = State(initialValue: ARSurveyViewModel(route: route))
    }

    var body: some View {
        ZStack {
            if vm.isReady {
                ARSurveySceneView(vm: vm).ignoresSafeArea()
                if vm.isFramingSignImage { ARSignFramingGuide() }
                else if vm.isSceneInteractive && vm.placementQuality == .none { ARSurveyCenterRing() }
                overlay
            } else if vm.isLoading {
                ProgressView("Opening survey…")
            } else {
                ContentUnavailableView(vm.message ?? "This survey could not be opened.",
                                       systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(vm.metadata.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .onDisappear { vm.stop() }
        .sheet(item: $vm.pendingSign) { _ in
            ARSignDetailsSheet(
                onSave: { label, kind, hasArrow in vm.confirmSign(label: label, kind: kind, hasArrow: hasArrow) },
                onCancel: { vm.cancelPendingSign() })
        }
        .sheet(item: $vm.pendingSignImage) { pending in
            ARSignImageNameSheet(
                image: pending.image,
                onSave: { vm.confirmSignImage(name: $0) },
                onCancel: { vm.cancelPendingSignImage() })
        }
        .sheet(isPresented: $vm.isEditingSelection) {
            ARSignDetailsSheet(
                editing: vm.selectedNode,
                onSave: { label, kind, _ in vm.confirmEdit(label: label, kind: kind) },
                onCancel: { vm.isEditingSelection = false })
        }
    }

    private var overlay: some View {
        VStack {
            HStack(alignment: .top) {
                ARSurveyHUD(vm: vm)
                Spacer()
            }
            if vm.showsCoaching { ARSurveyCoachingCard().padding(.top, DesignTokens.Space.l) }
            Spacer()
            if vm.isSceneInteractive && !vm.isFramingSignImage { ARSurveyPlacementHint(quality: vm.placementQuality) }
            if let message = vm.message { messageBanner(message) }
            if vm.isFramingSignImage {
                ARSignImageCaptureBar(
                    isCapturing: vm.isCapturingImage,
                    onCapture: { Task { await vm.captureSignImage() } },
                    onCancel: { vm.cancelSignImageFraming() })
            } else if vm.selectedNode != nil {
                ARSurveySelectionPanel(vm: vm)
            } else {
                controls
            }
        }
        .padding(DesignTokens.Space.l)
    }

    private func messageBanner(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.TypeScale.subtitle)
            .padding(DesignTokens.Space.m)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private var controls: some View {
        VStack(spacing: DesignTokens.Space.m) {
            addImageButton
            saveControls
        }
    }

    private var addImageButton: some View {
        Button("Add Sign Image", systemImage: "photo.badge.plus") { vm.beginSignImageFraming() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!vm.isSceneInteractive)
            .padding(DesignTokens.Space.s)
            .background(.regularMaterial, in: Capsule())
    }

    private var saveControls: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button("Undo Last Sign", systemImage: "arrow.uturn.backward") { vm.undoLastSign() }
                .buttonStyle(.bordered)
                .disabled(vm.signCount == 0)
            Button(vm.isSaving ? "Saving…" : "Save Survey", systemImage: "square.and.arrow.down") {
                Task { await vm.save() }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.action)
            .foregroundStyle(Color.licorice)
            .disabled(!vm.canSave)
        }
        .controlSize(.large)
        .padding(DesignTokens.Space.m)
        .background(.regularMaterial, in: Capsule())
    }
}
