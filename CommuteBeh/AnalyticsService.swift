import Foundation

final class AnalyticsService {
    static let shared = AnalyticsService()
    private let client = APIClient.shared

    private init() {}

    func logRoutePlan(origin: String, destination: String, lineIds: [String], durationSecs: Int) {
        client.send(.logRoutePlan(
            origin: origin,
            destination: destination,
            lineIds: lineIds,
            durationSecs: durationSecs
        ))
    }
}
