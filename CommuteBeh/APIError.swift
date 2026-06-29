import Foundation

enum APIError: Error {
    case unauthorized           // 401 — token expired or revoked
    case forbidden              // 403 — wrong role
    case notFound               // 404
    case unprocessable(String)  // 422 — validation error from server
    case tooManyRequests        // 429
    case serverError(Int)       // 5xx
    case decodingFailed(Error)
    case network(Error)

    var userMessage: String {
        switch self {
        case .unauthorized:           return "Session expired. Please sign in again."
        case .forbidden:              return "You don't have permission to do this."
        case .notFound:               return "This item no longer exists."
        case .unprocessable(let msg): return msg
        case .tooManyRequests:        return "Too many requests. Try again in a moment."
        case .serverError:            return "Something went wrong. Try again later."
        case .network:                return "Check your internet connection."
        case .decodingFailed:         return "Something went wrong. Try again later."
        }
    }
}

struct ErrorResponse: Decodable {
    let error: String
    let errors: [String]?
}
