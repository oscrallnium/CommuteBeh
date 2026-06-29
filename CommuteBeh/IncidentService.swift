import Foundation

final class IncidentService {
    static let shared = IncidentService()
    private let client = APIClient.shared

    private init() {}

    func activeIncidents() async throws -> [Incident] {
        let resp: APIResponse<[Incident]> = try await client.request(
            .incidents,
            responseType: APIResponse<[Incident]>.self
        )
        return resp.data
    }

    func report(stationId: String, description: String, category: String) async throws -> Incident {
        let resp: APIResponse<Incident> = try await client.request(
            .reportIncident(stationId: stationId, description: description, category: category),
            responseType: APIResponse<Incident>.self
        )
        return resp.data
    }
}
