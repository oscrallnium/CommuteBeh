//
//  SettingsDocumentView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// A pushed page that shows one legal document as grouped rows.
struct SettingsDocumentView: View {
    let document: SettingsDocument

    var body: some View {
        List {
            Section {
                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                        Text(section.heading).font(.headline)
                        Text(section.body).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DesignTokens.Space.xxs)
                }
            } header: {
                Text(document.effective)
            } footer: {
                Text(document.footer)
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
