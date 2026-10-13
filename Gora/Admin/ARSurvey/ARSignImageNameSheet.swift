//
//  ARSignImageNameSheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import SwiftUI

/// Shows the captured sign image and asks for its name.
struct ARSignImageNameSheet: View {
    let image: CGImage
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 140)
                        .frame(maxWidth: .infinity)
                }
                Section("Name") {
                    TextField("For example, MRT Ayala north exit sign", text: $name)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle("Sign Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onSave(trimmedName) }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
