//
//  ARSurveySelectionPanel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// The controls for the selected sign. They replace the bottom controls while a sign is selected.
struct ARSurveySelectionPanel: View {
    let vm: ARSurveyViewModel

    private var heading: Double? { vm.selectedNode?.arrowHeadingDegrees }
    private var hapticStep: Int { Int(((heading ?? 0) / 15).rounded(.down)) }

    var body: some View {
        VStack(spacing: DesignTokens.Space.m) {
            header
            rotateRow
            editRow
            endRow
        }
        .controlSize(.large)
        .padding(DesignTokens.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .sensoryFeedback(.selection, trigger: hapticStep)
    }

    @ViewBuilder
    private var header: some View {
        if let node = vm.selectedNode {
            VStack(spacing: DesignTokens.Space.xxs) {
                Label(node.label, systemImage: node.kind.symbolName)
                    .font(DesignTokens.TypeScale.subtitleEmphasis)
                Text("\(node.kind.displayName) · \(angleText)")
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var angleText: String {
        guard let heading else { return "No arrow" }
        return "Arrow \(Int(heading.rounded()))°"
    }

    private var rotateRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button("Rotate Left 15°", systemImage: "rotate.left") { vm.rotateSelectedArrow(byDegrees: -15) }
            Button("Rotate Right 15°", systemImage: "rotate.right") { vm.rotateSelectedArrow(byDegrees: 15) }
        }
        .buttonStyle(.bordered)
        .disabled(heading == nil)
    }

    private var editRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button(heading == nil ? "Add Arrow" : "Remove Arrow", systemImage: "arrow.up") {
                vm.toggleSelectedArrow()
            }
            Button("Edit", systemImage: "pencil") { vm.isEditingSelection = true }
        }
        .buttonStyle(.bordered)
    }

    private var endRow: some View {
        HStack(spacing: DesignTokens.Space.m) {
            Button("Delete Sign", systemImage: "trash", role: .destructive) { vm.deleteSelectedSign() }
                .buttonStyle(.bordered)
            Button("Done") { vm.clearSelection() }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.Colors.action)
                .foregroundStyle(Color.licorice)
        }
    }
}
