import Foundation

final class GraphService {
    static let shared = GraphService()
    private let client = APIClient.shared

    private init() {}

    func currentVersion() async throws -> GraphVersion {
        let resp: APIResponse<GraphVersion> = try await client.request(
            .graphVersion,
            responseType: APIResponse<GraphVersion>.self
        )
        return resp.data
    }

    // Returns raw JSON data — parse with your transit graph model
    func fetchGraph() async throws -> Data {
        let req = try APIEndpoint.graph.urlRequest()
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
