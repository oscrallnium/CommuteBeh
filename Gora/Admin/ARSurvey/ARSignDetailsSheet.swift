//
//  ARSignDetailsSheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// Asks for the label and the kind of a sign. A new sign also asks for a direction arrow.
struct ARSignDetailsSheet: View {
    let editing: ARSurveyNode?
    let onSave: (String, ARSignKind, Bool) -> Void
    let onCancel: () -> Void

    @State private var label: String
    @State private var kind: ARSignKind
    @State private var hasArrow = true

    init(editing: ARSurveyNode? = nil,
         onSave: @escaping (String, ARSignKind, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.editing = editing
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: editing?.label ?? "")
        _kind = State(initialValue: editing?.kind ?? .exit)
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("For example, Exit A", text: $label)
                        .textInputAutocapitalization(.words)
                }
                Section("Kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach(ARSignKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if editing == nil {
                    Section {
                        Toggle("Direction Arrow", isOn: $hasArrow)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Sign" : "Edit Sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Place" : "Save") { onSave(trimmedLabel, kind, hasArrow) }
                        .disabled(trimmedLabel.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
