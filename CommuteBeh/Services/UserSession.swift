//
//  UserSession.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 7/7/26.
//

import Foundation

@Observable
@MainActor
final class UserSession {
    var isLoggedIn = false
    var currentUser: UserProfile?

    var isAdmin: Bool { currentUser?.role == "admin" }

    private static let profileKey = "com.commutebeh.userProfile"

    init() {
        // Restore cached session if a token still exists in Keychain
        if Keychain.load() != nil,
           let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            currentUser = profile
            isLoggedIn = true
            // Silently refresh — revokes old token and issues a new one
            Task { await refreshSession() }
        }

        // Any 401 from the API layer broadcasts this; force a sign-out
        NotificationCenter.default.addObserver(
            forName: .sessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.clearSession() }
        }
    }

    func login(user: UserProfile) {
        currentUser = user
        isLoggedIn = true
        persist(user)
    }

    func logout() async {
        await AuthService.shared.signOut()   // revokes token server-side, clears Keychain
        clearSession()
    }

    // MARK: Private

    private func refreshSession() async {
        do {
            let user = try await AuthService.shared.refresh()
            currentUser = user
            persist(user)
        } catch APIError.unauthorized {
            // Token was revoked — force the user back to login
            clearSession()
        } catch {
            // Network failure — keep showing the cached profile until connectivity returns
        }
    }

    private func persist(_ user: UserProfile) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: Self.profileKey)
    }

    private func clearSession() {
        // Keychain.delete() is called by AuthService.signOut / AuthService.refresh on 401
        // but we call it here too in case clearSession is triggered by the notification path
        Keychain.delete()
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        currentUser = nil
        isLoggedIn = false
    }
}
