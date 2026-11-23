//
//  AppleSignInService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import AuthenticationServices
import CryptoKit
import Security

struct AppleCredential: Sendable {
    let idToken: String
    let rawNonce: String
    let authorizationCode: String?
    let fullName: String?
}

@MainActor
final class AppleSignInService {
    // The controller holds its delegate weakly, so the service keeps both until completion.
    private var controller: ASAuthorizationController?
    private var delegate: AppleAuthorizationDelegate?

    func signIn() async throws -> AppleCredential {
        guard let anchor = KeyWindowProvider.keyWindow else { throw SocialSignInError.failed }
        let rawNonce = try Self.makeRawNonce()

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(rawNonce)

        defer { controller = nil; delegate = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = AppleAuthorizationDelegate(
                rawNonce: rawNonce, anchor: anchor, continuation: continuation)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            self.delegate = delegate
            self.controller = controller
            controller.performRequests()
        }
    }

    private static func makeRawNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SocialSignInError.failed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class AppleAuthorizationDelegate: NSObject,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let rawNonce: String
    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<AppleCredential, Error>?

    init(rawNonce: String, anchor: ASPresentationAnchor,
         continuation: CheckedContinuation<AppleCredential, Error>) {
        self.rawNonce = rawNonce
        self.anchor = anchor
        self.continuation = continuation
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let idToken = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential?.fullName.flatMap(Self.formattedName)
        Task { @MainActor in
            guard let idToken else { return self.finish(.failure(SocialSignInError.failed)) }
            self.finish(.success(AppleCredential(
                idToken: idToken, rawNonce: self.rawNonce,
                authorizationCode: code, fullName: name)))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let isCancelled = (error as? ASAuthorizationError)?.code == .canceled
        Task { @MainActor in
            self.finish(.failure(isCancelled ? SocialSignInError.cancelled : SocialSignInError.failed))
        }
    }

    // Resumes the continuation once; later calls find it nil and do nothing.
    private func finish(_ result: Result<AppleCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    private nonisolated static func formattedName(_ components: PersonNameComponents) -> String? {
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
