//
//  ARSurveyListView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// Entry view: the saved surveys and the button that starts a new one.
struct ARSurveyListView: View {
    @State private var vm = ARSurveyListViewModel()
    @State private var showNewSurvey = false
    @State private var route: ARSurveyRoute?
    @State private var surveyToDelete: ARSurveySummary?

    var body: some View {
        List {
            if vm.surveys.isEmpty {
                ContentUnavailableView("No surveys yet", systemImage: "camera.viewfinder",
                                       description: Text("Tap New Survey to scan a place and place signs."))
            }
            ForEach(vm.surveys) { survey in
                Button { route = .replay(survey.id) } label: { ARSurveyRow(survey: survey) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) { surveyToDelete = survey }
                    }
            }
        }
        .navigationTitle("AR Surveys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Survey", systemImage: "plus") { showNewSurvey = true }
            }
        }
        .task { await vm.reload() }
        .sheet(isPresented: $showNewSurvey) {
            ARNewSurveySheet { draft in route = .new(draft) }
        }
        .navigationDestination(item: $route) { ARSurveyView(route: $0) }
        .confirmationDialog(
            "Delete this survey?", isPresented: deleteDialogBinding, presenting: surveyToDelete
        ) { survey in
            Button("Delete \(survey.metadata.name)", role: .destructive) {
                Task { await vm.delete(survey) }
            }
        } message: { _ in
            Text("The signs and the saved map are removed from this iPhone.")
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { surveyToDelete != nil }, set: { if !$0 { surveyToDelete = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })
    }
}

// MARK: - Row

private struct ARSurveyRow: View {
    let survey: ARSurveySummary

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            HStack {
                Text(survey.metadata.name).font(DesignTokens.TypeScale.rowTitle)
                Spacer()
                if !survey.errors.isEmpty || !survey.warnings.isEmpty { warningBadge }
            }
            Text(survey.metadata.zoneName)
                .font(DesignTokens.TypeScale.subtitle)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(DesignTokens.TypeScale.meta)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        let signs = "\(survey.metadata.nodes.count) signs"
        let size = Int64(survey.metadata.captureContext.sizeBytes).formatted(.byteCount(style: .file))
        let date = survey.metadata.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return [signs, size, date].joined(separator: " · ")
    }

    private var warningBadge: some View {
        Label(survey.errors.isEmpty ? "Warning" : "Check scan", systemImage: "exclamationmark.triangle.fill")
            .font(DesignTokens.TypeScale.meta.weight(.semibold))
            .foregroundStyle(survey.errors.isEmpty ? Color.ember : Color.vermilion)
            .accessibilityHint((survey.errors + survey.warnings).joined(separator: " "))
    }
}
