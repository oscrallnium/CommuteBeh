//
//  ScheduleStatus.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import Foundation

extension RouteResult {
    /// True when a leg boards a line that runs on a timetable.
    var hasScheduledLeg: Bool {
        legs.contains { $0.scheduledDeparture != nil }
    }
}

/// What the route card shows for the first timetable leg of a route at one moment.
/// The rider reaches the boarding stop after a fixed time, so only `now` changes the result.
struct ScheduleStatus: Equatable {
    enum State: Equatable {
        /// The rider can wait for the departure within the maximum wait.
        case ready
        /// The departure is today but the wait is longer than the maximum wait.
        case tooEarly
        /// Today has trips, but the next catchable trip is on a later day.
        case noMoreToday
        /// Today has no service.
        case noServiceToday
    }

    enum TripRole: Equatable {
        /// The trip passed the stop before now.
        case left
        /// The trip passes the stop before the rider arrives.
        case tooSoon
        /// The first trip the rider can catch.
        case next
        case later
    }

    /// One time the vehicle passes the boarding stop.
    struct Trip: Identifiable, Equatable {
        let time: Date
        let role: TripRole
        var id: Date { time }
    }

    let state: State
    let legID: UUID
    let mode: TransportMode
    /// The first trip the rider can catch. Nil when the timetable lists none in its look-ahead.
    let departure: Date?
    /// Minutes between the rider's arrival at the stop and the departure. Zero without a departure.
    let waitMinutes: Double
    /// The time the wait drops to the maximum wait. Non-nil only in `.tooEarly`.
    let availableFrom: Date?
    /// Arrival of the route when the rider takes `departure`.
    let arrival: Date?
    /// Arrival of the scheduled leg when the rider takes `departure`.
    let legArrival: Date?
    /// Every trip of today at the boarding stop.
    let todayTrips: [Trip]
    /// The next trip on a later day. Non-nil only in `.noMoreToday` and `.noServiceToday`.
    let nextTrip: Date?
    /// The note of the exception that closes today. Non-nil only in `.noServiceToday`.
    let note: String?

    private enum Config {
        static let timeZoneID = "Asia/Manila"
        static let secondsPerMinute = 60.0
        static let sameInstantTolerance: TimeInterval = 1
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: Config.timeZoneID) ?? .current
        return calendar
    }()

    /// `offsetMinutes` is the ride time from the first stop of the line to the boarding stop.
    /// Returns nil when no leg of `legs` boards a timetable line.
    init?(legs: [RouteLeg], timetable: ServiceTimetable, offsetMinutes: Double, now: Date) {
        guard let index = legs.firstIndex(where: { $0.scheduledDeparture != nil }),
              let planned = legs[index].scheduledDeparture else { return nil }
        let leg = legs[index]
        let reachMinutes = legs[..<index].reduce(0) { $0 + $1.effectiveTravelMinutes + ($1.waitMinutes ?? 0) }
        let arriveAtStop = now.addingTimeInterval(reachMinutes * Config.secondsPerMinute)
        let offset = offsetMinutes * Config.secondsPerMinute

        let departure = planned >= arriveAtStop
            ? planned
            : timetable.nextDeparture(line: leg.line, direction: leg.direction,
                                      atOrAfter: arriveAtStop.addingTimeInterval(-offset))?
                .addingTimeInterval(offset)
        let service = timetable.service(line: leg.line, direction: leg.direction, on: now)

        let trips = timetable.departures(line: leg.line, direction: leg.direction, on: now).map { terminal in
            let time = terminal.addingTimeInterval(offset)
            return Trip(time: time, role: Self.role(of: time, now: now, arriveAtStop: arriveAtStop, next: departure))
        }

        let shift = departure.map { $0.timeIntervalSince(planned) } ?? 0
        let wait = departure.map { max(0, $0.timeIntervalSince(arriveAtStop) / Config.secondsPerMinute) } ?? 0
        let maxWait = Double(timetable.maxWaitMinutes)

        var state = State.noMoreToday
        var note: String?
        if case .noService(let closedNote) = service {
            state = .noServiceToday
            note = closedNote
        } else if let departure, Self.calendar.isDate(departure, inSameDayAs: now) {
            state = wait <= maxWait ? .ready : .tooEarly
        }
        let isToday = state == .ready || state == .tooEarly

        self.state = state
        self.legID = leg.id
        self.mode = leg.mode
        self.departure = departure
        self.waitMinutes = wait
        self.availableFrom = state == .tooEarly
            ? departure?.addingTimeInterval(-(maxWait + reachMinutes) * Config.secondsPerMinute) : nil
        self.arrival = legs.last.map { $0.estimatedArrival.addingTimeInterval(shift) }
        self.legArrival = leg.estimatedArrival.addingTimeInterval(shift)
        self.todayTrips = trips
        self.nextTrip = isToday ? nil : departure
        self.note = note
    }

    private static func role(of time: Date, now: Date, arriveAtStop: Date, next: Date?) -> TripRole {
        if let next, abs(time.timeIntervalSince(next)) < Config.sameInstantTolerance { return .next }
        if time < now { return .left }
        if time < arriveAtStop { return .tooSoon }
        return .later
    }
}
