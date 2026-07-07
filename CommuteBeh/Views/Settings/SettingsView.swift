//
//  SettingsView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(UserSession.self) private var session
    @State private var isLoggingOut = false

    var body: some View {
        NavigationStack {
            List {
                if let user = session.currentUser {
                    Section("Account") {
                        LabeledContent("Name", value: user.displayName)
                        LabeledContent("Email", value: user.email)
                        LabeledContent("Role", value: user.role.capitalized)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await logout() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingOut {
                                ProgressView()
                            } else {
                                Text("Sign Out")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoggingOut)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func logout() async {
        isLoggingOut = true
        await session.logout()
        // session.isLoggedIn flips to false → CommuteBehApp shows LoginView
    }
}
