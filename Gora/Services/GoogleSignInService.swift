//
//  GoogleSignInService.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import GoogleSignIn

@MainActor
final class GoogleSignInService {
    /// Returns the Google ID token. GoogleSignIn reads the client ID from `GIDClientID`.
    func signIn() async throws -> String {
        guard let presenter = KeyWindowProvider.topViewController else {
            throw SocialSignInError.failed
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw SocialSignInError.failed
            }
            // The Gora JWT is the only session, so the Google session ends here.
            GIDSignIn.sharedInstance.signOut()
            return idToken
        } catch let error as GIDSignInError where error.code == .canceled {
            throw SocialSignInError.cancelled
        }
    }
}
