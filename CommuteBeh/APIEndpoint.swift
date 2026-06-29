import Foundation

enum APIEndpoint {
    // Auth
    case register(email: String, password: String, confirmation: String, displayName: String)
    case signIn(email: String, password: String)
    case signOut
    case refreshToken
    case deleteAccount

    // User
    case me
    case updateMe(displayName: String?, homeStationId: String?)

    // Graph
    case graphVersion
    case graph

    // Stations
    case stations(query: String?)
    case station(id: String)

    // Routes
    case routes
    case route(lineId: String)

    // Saved routes
    case savedRoutes
    case createSavedRoute(name: String, origin: String, destination: String, lineIds: [String])
    case deleteSavedRoute(id: String)

    // Incidents
    case incidents
    case reportIncident(stationId: String, description: String, category: String)

    // Analytics
    case logRoutePlan(origin: String, destination: String, lineIds: [String], durationSecs: Int)

    func urlRequest() throws -> URLRequest {
        let base = URL(string: APIConfig.baseURL)!
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let q = queryItems { components.queryItems = q }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if let body = body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    private var path: String {
        switch self {
        case .register:                    return "/auth/register"
        case .signIn:                      return "/auth/sign_in"
        case .signOut:                     return "/auth/sign_out"
        case .refreshToken:                return "/api/v1/auth/refresh"
        case .deleteAccount:               return "/api/v1/auth/account"
        case .me:                          return "/api/v1/me"
        case .updateMe:                    return "/api/v1/me"
        case .graphVersion:                return "/api/v1/graph/version"
        case .graph:                       return "/api/v1/graph"
        case .stations:                    return "/api/v1/stations"
        case .station(let id):             return "/api/v1/stations/\(id)"
        case .routes:                      return "/api/v1/routes"
        case .route(let lineId):           return "/api/v1/routes/\(lineId)"
        case .savedRoutes:                 return "/api/v1/saved_routes"
        case .createSavedRoute:            return "/api/v1/saved_routes"
        case .deleteSavedRoute(let id):    return "/api/v1/saved_routes/\(id)"
        case .incidents:                   return "/api/v1/incidents"
        case .reportIncident:              return "/api/v1/incidents"
        case .logRoutePlan:                return "/api/v1/analytics/route_plan"
        }
    }

    private var method: String {
        switch self {
        case .register, .signIn, .refreshToken, .createSavedRoute, .reportIncident, .logRoutePlan:
            return "POST"
        case .updateMe:
            return "PATCH"
        case .signOut, .deleteAccount, .deleteSavedRoute:
            return "DELETE"
        default:
            return "GET"
        }
    }

    private var queryItems: [URLQueryItem]? {
        switch self {
        case .stations(let q) where q != nil:
            return [URLQueryItem(name: "q", value: q)]
        default:
            return nil
        }
    }

    private var body: [String: Any]? {
        switch self {
        case .register(let email, let password, let confirmation, let displayName):
            return ["user": ["email": email, "password": password,
                             "password_confirmation": confirmation, "display_name": displayName]]
        case .signIn(let email, let password):
            return ["user": ["email": email, "password": password]]
        case .updateMe(let displayName, let homeStationId):
            var user: [String: Any] = [:]
            if let d = displayName { user["display_name"] = d }
            if let h = homeStationId { user["home_station_id"] = h }
            return ["user": user]
        case .createSavedRoute(let name, let origin, let destination, let lineIds):
            return ["saved_route": ["name": name, "origin_station_id": origin,
                                    "destination_station_id": destination, "line_ids": lineIds]]
        case .reportIncident(let stationId, let description, let category):
            return ["incident": ["station_id": stationId, "description": description,
                                 "category": category]]
        case .logRoutePlan(let origin, let destination, let lineIds, let durationSecs):
            return ["event": ["origin_station_id": origin, "destination_station_id": destination,
                              "line_ids": lineIds, "duration_seconds": durationSecs]]
        default:
            return nil
        }
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}
