//
//  ServiceTimetableTests.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

// No GoraTests target exists, so this follows the `TrackSnapperValidation` pattern.
// Move each case into a Swift Testing `@Test` function once the target exists.

import Foundation

enum ServiceTimetableValidation {

    private static let line = "TEST_LINE"
    private static let weekdays = ["mon", "tue", "wed", "thu", "fri"]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila") ?? .current
        return calendar
    }

    private static func manila(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func check(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    static func runAll() -> [String] {
        var failures: [String] = []
        weekdayDepartures(&failures)
        noSundayTripsRollToMonday(&failures)
        noServiceException(&failures)
        departuresExceptionReplacesRegular(&failures)
        directionSpecificWins(&failures)
        windowAcrossMidnight(&failures)
        decodeDefaultsAndKeys(&failures)
        rideOffsetsFollowDirection(&failures)
        waitIncludesRideOffset(&failures)
        return failures
    }

    private static func weekdayRule(direction: String? = nil, times: [String]) -> ServiceScheduleRule {
        ServiceScheduleRule(direction: direction, kind: .departures, departures: times, days: weekdays)
    }

    // 2026-11-16 is a Monday; 2026-11-15 is a Sunday.
    private static func weekdayDepartures(_ failures: inout [String]) {
        let table = ServiceTimetable(schedules: [line: [weekdayRule(times: ["17:30", "05:30", "06:15"])]])
        check(table.hasTimetable(line: line), "line with rows should have a timetable", &failures)
        check(!table.hasTimetable(line: "OTHER"), "line without rows should have no timetable", &failures)
        check(table.service(line: "OTHER", direction: nil, on: manila(2026, 11, 16)) == .unrestricted,
              "line without rows should be unrestricted", &failures)
        check(table.service(line: line, direction: nil, on: manila(2026, 11, 16)) == .departures([330, 375, 1050]),
              "Monday should list sorted departures", &failures)
        check(table.nextDeparture(line: line, direction: nil, atOrAfter: manila(2026, 11, 16, 6, 0)) == manila(2026, 11, 16, 6, 15),
              "next trip after 06:00 should be 06:15", &failures)
        check(table.departures(line: line, direction: nil, on: manila(2026, 11, 16)).count == 3,
              "Monday should return three departure dates", &failures)
    }

    private static func noSundayTripsRollToMonday(_ failures: inout [String]) {
        let table = ServiceTimetable(schedules: [line: [weekdayRule(times: ["05:30"])]])
        check(table.service(line: line, direction: nil, on: manila(2026, 11, 15)) == .noService(note: nil),
              "Sunday should have no service", &failures)
        check(table.nextDeparture(line: line, direction: nil, atOrAfter: manila(2026, 11, 15, 10, 0)) == manila(2026, 11, 16, 5, 30),
              "Sunday morning should roll to Monday 05:30", &failures)
        check(table.nextDeparture(line: line, direction: nil, atOrAfter: manila(2026, 11, 16, 18, 0)) == manila(2026, 11, 17, 5, 30),
              "Monday evening should roll to Tuesday 05:30", &failures)
    }

    private static func noServiceException(_ failures: inout [String]) {
        let holiday = ServiceScheduleException(kind: .noService, note: "Holiday", from: "2026-11-17", to: "2026-11-17")
        let table = ServiceTimetable(schedules: [line: [weekdayRule(times: ["05:30"])]], exceptions: [line: [holiday]])
        check(table.service(line: line, direction: nil, on: manila(2026, 11, 17, 12)) == .noService(note: "Holiday"),
              "exception date should have no service with its note", &failures)
        check(table.nextDeparture(line: line, direction: nil, atOrAfter: manila(2026, 11, 16, 18, 0)) == manila(2026, 11, 18, 5, 30),
              "next trip should skip the exception date", &failures)
    }

    private static func departuresExceptionReplacesRegular(_ failures: inout [String]) {
        let special = ServiceScheduleException(kind: .departures, departures: ["07:00"], from: "2026-11-16", to: "2026-11-16")
        let table = ServiceTimetable(schedules: [line: [weekdayRule(times: ["05:30", "06:15"])]], exceptions: [line: [special]])
        check(table.service(line: line, direction: nil, on: manila(2026, 11, 16)) == .departures([420]),
              "exception departures should replace the regular list", &failures)
        check(table.service(line: line, direction: nil, on: manila(2026, 11, 17)) == .departures([330, 375]),
              "the day after the exception should use the regular list", &failures)
    }

    private static func directionSpecificWins(_ failures: inout [String]) {
        let rules = [weekdayRule(times: ["05:00"]), weekdayRule(direction: "northbound", times: ["06:00"])]
        let table = ServiceTimetable(schedules: [line: rules])
        let monday = manila(2026, 11, 16)
        check(table.service(line: line, direction: "northbound", on: monday) == .departures([360]),
              "northbound should use its own row", &failures)
        check(table.service(line: line, direction: "southbound", on: monday) == .departures([300]),
              "southbound should use the direction-less row", &failures)
    }

    private static func windowAcrossMidnight(_ failures: inout [String]) {
        let rule = ServiceScheduleRule(kind: .window, start: "22:00", end: "02:00")
        let table = ServiceTimetable(schedules: [line: [rule]])
        check(table.isRunning(line: line, direction: nil, at: manila(2026, 11, 16, 23, 0)), "23:00 should run", &failures)
        check(table.isRunning(line: line, direction: nil, at: manila(2026, 11, 17, 1, 0)), "01:00 should run", &failures)
        check(!table.isRunning(line: line, direction: nil, at: manila(2026, 11, 16, 12, 0)), "12:00 should not run", &failures)
        check(table.nextDeparture(line: line, direction: nil, atOrAfter: manila(2026, 11, 16, 12, 0)) == manila(2026, 11, 16, 22, 0),
              "next window opening should be 22:00", &failures)
    }

    private static func decodeDefaultsAndKeys(_ failures: inout [String]) {
        let rule = #"{"direction":"northbound","kind":"departures","departures":["05:30"],"days":["mon"]}"#
        let item = #"{"kind":"no_service","note":"Holiday","id":"x","from":"2026-12-24","to":"2026-12-25"}"#
        let json = #"{"serviceSchedules":{"L":[\#(rule)]},"serviceScheduleExceptions":{"L":[\#(item)]},"scheduledMaxWaitMinutes":45}"#
        struct Keys: Decodable {
            var scheduledMaxWaitMinutes: Int?
            var serviceSchedules: [String: [ServiceScheduleRule]]?
            var serviceScheduleExceptions: [String: [ServiceScheduleException]]?
        }
        let decoded = try? JSONDecoder().decode(Keys.self, from: Data(json.utf8))
        check(decoded?.scheduledMaxWaitMinutes == 45, "max wait should decode", &failures)
        check(decoded?.serviceSchedules?["L"]?.first?.kind == .departures, "rule kind should decode", &failures)
        check(decoded?.serviceScheduleExceptions?["L"]?.first?.kind == .noService, "exception kind should decode", &failures)
        let bare = try? JSONDecoder().decode(Keys.self, from: Data("{}".utf8))
        check(bare != nil && bare?.serviceSchedules == nil, "missing keys should decode as nil", &failures)
        let empty = ServiceTimetable(schedules: bare?.serviceSchedules ?? [:], exceptions: [:], maxWaitMinutes: bare?.scheduledMaxWaitMinutes ?? 60)
        check(empty.maxWaitMinutes == 60 && !empty.hasTimetable(line: "L"), "missing keys should give 60 and no timetable", &failures)
    }

    private static func edge(_ from: String, _ to: String, minutes: Double, direction: String? = "northbound") -> TransitEdge {
        TransitEdge(
            id: "\(from)-\(to)", from: from, to: to, mode: "bus", line: line, travelTimeMinutes: minutes,
            distanceKm: 1, baseFare: 0, farePerKm: 0, acceptedPayments: [], isAirConditioned: false,
            crowdFactor: 0, reliability: 1, bidirectional: false, direction: direction,
            polylineCoordinates: [], mkDirectionsTransportType: "automobile", isRoadSnapped: nil
        )
    }

    private static func rideOffsetsFollowDirection(_ failures: inout [String]) {
        let chain = [edge("A", "B", minutes: 8), edge("B", "C", minutes: 12)]
        let offsets = ScheduledBoarding.rideOffsets(chain)
        check(offsets["A"] == 0 && offsets["B"] == 8 && offsets["C"] == 20,
              "offsets should accumulate from the first stop", &failures)
        let loop = [edge("A", "B", minutes: 5), edge("B", "A", minutes: 5)]
        check(ScheduledBoarding.rideOffsets(loop).isEmpty, "a cycle with no first stop should give no offsets", &failures)
    }

    private static func waitIncludesRideOffset(_ failures: inout [String]) {
        let table = ServiceTimetable(schedules: [line: [ServiceScheduleRule(kind: .departures, departures: ["05:00", "13:00"])]])
        func wait(_ hour: Int, _ minute: Int) -> ScheduledWait? {
            ScheduledBoarding.wait(arrive: manila(2026, 11, 16, hour, minute), offsetMinutes: 20,
                                   line: line, direction: nil, timetable: table)
        }
        check(wait(12, 30)?.departure == manila(2026, 11, 16, 13, 20) && wait(12, 30)?.minutes == 50,
              "arrival 12:30 should board at 13:20 after 50 minutes", &failures)
        check(wait(13, 25)?.departure == manila(2026, 11, 17, 5, 20),
              "arrival 13:25 should board the next day at 05:20", &failures)
        check(wait(13, 20)?.minutes == 0, "arrival at the pass time should not wait", &failures)
    }
}
