import Foundation

final class AuthService {
    static let shared = AuthService()
    private let client = APIClient.shared

    private init() {}

    func register(email: String, password: String, displayName: String) async throws -> UserProfile {
        let resp: APIResponse<AuthPayload> = try await client.request(
            .register(email: email, password: password,
                      confirmation: password, displayName: displayName),
            responseType: APIResponse<AuthPayload>.self
        )
        Keychain.save(token: resp.data.token)
        return resp.data.user
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        let resp: APIResponse<AuthPayload> = try await client.request(
            .signIn(email: email, password: password),
            responseType: APIResponse<AuthPayload>.self
        )
        Keychain.save(token: resp.data.token)
        return resp.data.user
    }

    // Call on app launch when a token is already stored, before it expires
    func refresh() async throws -> UserProfile {
        let resp: APIResponse<AuthPayload> = try await client.request(
            .refreshToken,
            responseType: APIResponse<AuthPayload>.self
        )
        Keychain.save(token: resp.data.token)  // old token is immediately revoked server-side
        return resp.data.user
    }

    func signOut() async {
        _ = try? await client.request(.signOut, responseType: EmptyResponse.self)
        Keychain.delete()
    }

    func deleteAccount() async throws {
        _ = try? await client.request(.deleteAccount, responseType: EmptyResponse.self)
        Keychain.delete()
    }
}
