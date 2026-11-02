//
//  SettingsProfileView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// The Profile page: edit the display name and delete the account.
struct SettingsProfileView: View {
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showDeleteAlert = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !isWorking && !trimmedName.isEmpty && trimmedName != session.currentUser?.displayName
    }

    var body: some View {
        List {
            header
            personalInformation
            deleteSection
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .onAppear { name = session.currentUser?.displayName ?? "" }
        .alert("Delete Account?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("This permanently removes your profile, saved places and trip history.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: DesignTokens.Space.s) {
                SettingsAvatar(name: session.currentUser?.displayName ?? "", diameter: 96,
                               font: .largeTitle.bold())
                Text(session.currentUser?.displayName ?? "").font(.title2.bold())
                Text(session.currentUser?.email ?? "").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private var personalInformation: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.name)
            }
            LabeledContent("Email", value: session.currentUser?.email ?? "")
        } header: {
            Text("Personal Information")
        } footer: {
            Text("Your name appears on your profile and in support requests.")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Text("Delete Account").frame(maxWidth: .infinity)
            }
            .disabled(isWorking)
        } footer: {
            Text("Deleting your account permanently removes your profile, saved places and trip history. This can't be undone.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.updateDisplayName(trimmedName)
            dismiss()
        } catch {
            errorMessage = "Your name could not be saved. Try again."
        }
    }

    private func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.deleteAccount()
        } catch {
            errorMessage = "Your account could not be deleted. Try again."
        }
    }
}
