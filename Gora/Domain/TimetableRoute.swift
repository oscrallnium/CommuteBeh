//
//  TimetableRoute.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import Foundation

extension RouteResult {
    /// True when a leg boards a vehicle of a timetable line.
    var hasTimetableLeg: Bool { legs.contains { $0.scheduledDeparture != nil } }

    /// Route time without the wait for a timetable vehicle. `totalTimeMinutes` includes the wait.
    var minutesWithoutWait: Double { totalTimeMinutes - legs.reduce(0) { $0 + ($1.waitMinutes ?? 0) } }
}

extension TransitGraphEngine {
    /// The best route that rides a timetable line, as an extra option beside `shown`. Nil when
    /// a shown route has a timetable leg, no such route exists, `shown` holds it, or its time
    /// without the wait exceeds the fastest shown time.
    func timetableExtra(besides shown: [RouteResult], request: RouteRequest) -> RouteResult? {
        guard scheduledBoarding.hasScheduledLines, !shown.contains(where: \.hasTimetableLeg),
              let fastest = shown.map(\.totalTimeMinutes).min(),
              case .success(let result) = findRoute(request), result.hasTimetableLeg,
              result.minutesWithoutWait <= fastest else { return nil }
        let key = RouteDiversityPolicy.routeKey(result)
        return shown.contains { RouteDiversityPolicy.routeKey($0) == key } ? nil : result
    }
}
