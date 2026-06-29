import Foundation

final class APIClient {
    static let shared = APIClient()
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {}

    func request<T: Decodable>(
        _ endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T {
        var urlRequest = try endpoint.urlRequest()
        if let token = Keychain.load() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decodingFailed(error)
            }
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 422:
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? "Validation failed"
            throw APIError.unprocessable(msg)
        case 429:
            throw APIError.tooManyRequests
        default:
            throw APIError.serverError(http.statusCode)
        }
    }

    // Fire-and-forget variant used for analytics (never blocks the caller)
    func send(_ endpoint: APIEndpoint) {
        Task {
            var urlRequest = (try? endpoint.urlRequest()) ?? URLRequest(url: URL(string: APIConfig.baseURL)!)
            if let token = Keychain.load() {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await session.data(for: urlRequest)
        }
    }
}
