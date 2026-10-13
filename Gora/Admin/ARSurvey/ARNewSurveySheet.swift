//
//  ARNewSurveySheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import SwiftUI

/// Asks for the name, the zone name, and the light condition of a new survey.
struct ARNewSurveySheet: View {
    let onStart: (ARSurveyMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var zoneName = ""
    @State private var light: ARLightCondition = .day

    private var canStart: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !zoneName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Survey name", text: $name)
                    TextField("Zone name, for example Cubao concourse", text: $zoneName)
                }
                Section("Light") {
                    Picker("Light", selection: $light) {
                        ForEach(ARLightCondition.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Survey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Scan", action: start).disabled(!canStart)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func start() {
        let draft = ARSurveyMetadata.new(
            name: name.trimmingCharacters(in: .whitespaces),
            zoneName: zoneName.trimmingCharacters(in: .whitespaces),
            light: light,
            deviceModel: ARSurveyViewModel.deviceModel,
            iosVersion: UIDevice.current.systemVersion)
        dismiss()
        onStart(draft)
    }
}
