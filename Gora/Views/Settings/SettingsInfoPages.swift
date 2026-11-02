//
//  SettingsInfoPages.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// Placeholder page for Download My Data. It shows the account email.
struct SettingsDownloadDataView: View {
    @Environment(UserSession.self) private var session

    var body: some View {
        List {
            Section {
                if let email = session.currentUser?.email {
                    LabeledContent("Email", value: email)
                }
            } footer: {
                Text("A copy of your data will be available here soon. We will send it to this email address.")
            }
        }
        .navigationTitle("Download My Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder page for Report a Route Problem.
struct SettingsRouteReportView: View {
    var body: some View {
        ContentUnavailableView(
            "Coming Soon",
            systemImage: "exclamationmark.bubble",
            description: Text("Route reports are coming soon. For now, contact support and describe the problem."))
            .navigationTitle("Report a Route Problem")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Lists the open-source software the app uses.
struct SettingsAcknowledgementsView: View {
    var body: some View {
        List {
            Text("Firebase iOS SDK — Apache License 2.0")
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
