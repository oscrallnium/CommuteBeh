//
//  LoginView.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import SwiftUI

struct LoginView: View {
    @Environment(UserSession.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "tram.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.ember)
                Text("Gora")
                    .font(.system(.largeTitle, weight: .bold))
                Text("Metro Manila Transit Navigator")
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(.caption))
                    .foregroundStyle(Color.vermilion)
                    .multilineTextAlignment(.center)
            }

            Button {
                focusedField = nil
                Task { await signIn() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Sign In")
                            .font(.system(.body, weight: .semibold))
                    }
                }
                .foregroundStyle(DesignTokens.Colors.onAction)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.action)
            .disabled(isLoading || email.isEmpty || password.isEmpty)

            Spacer()
        }
        .padding(24)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var closeButton: some View {
        Button {
            focusedField = nil
            session.dismissLogin()
        } label: {
            Image(systemName: "xmark")
                .font(.system(.body, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(isLoading)
        .accessibilityLabel("Close")
        .padding(.trailing, 16)
        .padding(.top, 8)
    }

    private func signIn() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let user = try await AuthService.shared.signIn(email: email, password: password)
            session.login(user: user)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Try again."
        }
    }
}
