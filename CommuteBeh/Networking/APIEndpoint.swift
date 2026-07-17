//
//  APIEndpoint.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 6/30/26.
//

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

    // Admin
    case updateStation(id: String, update: StationUpdate)
    case updateEdge(id: String, polylineCoordinates: [Coordinates])
    case deleteRoute(lineId: String)
    case adminSettings
    case updateAdminSettings(enforceOperatingHours: Bool)

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
        case .updateStation(let id, _): return "/api/v1/admin/stations/\(id)"
        case .updateEdge(let id, _):    return "/api/v1/admin/edges/\(id)"
        case .deleteRoute(let lineId):  return "/api/v1/admin/graph/routes/\(lineId)"
        case .adminSettings:            return "/api/v1/admin/settings"
        case .updateAdminSettings:      return "/api/v1/admin/settings"
        }
    }

    private var method: String {
        switch self {
        case .register, .signIn, .refreshToken, .createSavedRoute, .reportIncident, .logRoutePlan:
            return "POST"
        case .updateMe, .updateStation, .updateEdge, .updateAdminSettings:
            return "PATCH"
        case .signOut, .deleteAccount, .deleteSavedRoute, .deleteRoute:
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
        case .updateStation(_, let update):
            var station: [String: Any] = [:]
            if let lat = update.latitude  { station["latitude"]   = lat }
            if let lng = update.longitude { station["longitude"]  = lng }
            if let n   = update.name      { station["name"]       = n   }
            if let sn  = update.shortName { station["short_name"] = sn  }
            if let ot  = update.openTime  { station["open_time"]  = ot  }
            if let ct  = update.closeTime { station["close_time"] = ct  }
            return station.isEmpty ? nil : ["station": station]
        case .updateEdge(_, let coords):
            let dicts = coords.map { ["lat": $0.lat, "lng": $0.lng] as [String: Any] }
            return ["edge": ["polyline_coordinates": dicts]]
        case .updateAdminSettings(let enforce):
            return ["enforce_operating_hours": enforce]
        default:
            return nil
        }
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}
