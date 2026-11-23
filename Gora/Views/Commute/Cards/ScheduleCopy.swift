//
//  ScheduleCopy.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import Foundation

// MARK: - Schedule Format

/// Clock, day, and duration text of the schedule parts. The POSIX locale makes each fixed format
/// exact, and the 12-hour format keeps a non-breaking space so the period never wraps alone.
enum ScheduleFormat {
    private enum Pattern {
        static let clock12 = "h:mm\u{00A0}a"
        static let clock24 = "HH:mm"
        static let spokenHour12 = "h a"
        static let spokenFull12 = "h:mm a"
        static let dayShort = "EEE"
        static let dayLong = "EEEE"
        static let locale = "en_US_POSIX"
    }

    private enum Span {
        static let hourLimit = 120
        static let minutesPerHour = 60
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: Pattern.locale)
        return formatter
    }

    private static let clock12 = formatter(Pattern.clock12)
    private static let clock24 = formatter(Pattern.clock24)
    private static let spokenHour12 = formatter(Pattern.spokenHour12)
    private static let spokenFull12 = formatter(Pattern.spokenFull12)
    private static let dayShort = formatter(Pattern.dayShort)
    private static let dayLong = formatter(Pattern.dayLong)

    /// "1:00 PM" or "13:00".
    static func time(_ date: Date, uses24HourTime: Bool) -> String {
        (uses24HourTime ? clock24 : clock12).string(from: date)
    }

    /// "1 PM", "1:30 PM", or "13:00".
    static func spokenTime(_ date: Date, uses24HourTime: Bool) -> String {
        if uses24HourTime { return clock24.string(from: date) }
        let isWholeHour = Calendar.current.component(.minute, from: date) == 0
        return (isWholeHour ? spokenHour12 : spokenFull12).string(from: date)
    }

    /// "Sat".
    static func day(_ date: Date) -> String { dayShort.string(from: date) }

    /// "Saturday".
    static func spokenDay(_ date: Date) -> String { dayLong.string(from: date) }

    /// "25 min", or "2 h 10 min" from two hours up.
    static func duration(minutes: Int) -> String {
        guard minutes >= Span.hourLimit else { return "\(minutes) min" }
        let hours = minutes / Span.minutesPerHour
        let rest = minutes % Span.minutesPerHour
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "25 minutes", or "2 hours 10 minutes".
    static func spokenDuration(minutes: Int) -> String {
        Duration.seconds(minutes * Span.minutesPerHour)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

// MARK: - Schedule Copy

/// Every string and symbol of the schedule parts for one `ScheduleStatus`.
struct ScheduleCopy {
    /// Symbol of the first status line.
    let symbol: String
    /// Semibold part of the first status line.
    let headline: String
    /// Secondary part of the first status line, such as "25 min wait".
    let detail: String?
    /// Second status line: the arrival or the next trip. Nil when the headline already says enough.
    let secondLine: String?
    /// Why Start Commute is off. Nil when the button is on.
    let buttonReason: String?
    /// The status lines as one spoken sentence group.
    let spoken: String
    /// Spoken once when the state becomes `.ready`.
    let announcement: String
    /// Semibold line of the expanded leg.
    let legHeadline: String
    /// Spoken label of the trip-times row.
    let tripsSpoken: String

    private enum Strings {
        static let leaves = "Leaves"
        static let arriveBy = "Arrive by"
        static let arrives = "Arrives"
        static let noWait = "No wait"
        static let wait = "wait"
        static let noMoreToday = "No more trips today"
        static let noTripsToday = "No trips today"
        static let nextTrip = "Next trip"
        static let noUpcoming = "No upcoming trips"
        static let availableFrom = "Available from"
        static let separator = " · "
        static let none = "none"
        static let left = "left"
        static let tooSoon = "too soon to catch"
        static let next = "next"
        static let tripTimesToday = "Trip times today:"
    }

    private enum SpokenStrings {
        static let leavesAt = "leaves at"
        static let minuteWait = "wait at the stop"
        static let noWait = "No wait."
        static let nextTripOn = "Next trip"
        static let at = "at"
        static let routeAvailable = "Route available."
    }

    init(_ status: ScheduleStatus, uses24HourTime: Bool) {
        let show = { (date: Date) in ScheduleFormat.time(date, uses24HourTime: uses24HourTime) }
        let speak = { (date: Date) in ScheduleFormat.spokenTime(date, uses24HourTime: uses24HourTime) }
        let minutes = Int(status.waitMinutes.rounded(.up))
        let arrivalText = status.arrival.map { "\(Strings.arriveBy) \(show($0))" } ?? ""
        let nextText = status.nextTrip.map { "\(Strings.nextTrip) \(ScheduleFormat.day($0)) \(show($0))" }
            ?? Strings.noUpcoming
        let nextSpoken = status.nextTrip.map {
            "\(SpokenStrings.nextTripOn) \(ScheduleFormat.spokenDay($0)) \(SpokenStrings.at) \(speak($0))."
        } ?? "\(Strings.noUpcoming)."

        switch status.state {
        case .ready, .tooEarly:
            let departure = status.departure ?? .now
            let isReady = status.state == .ready
            symbol = isReady ? "clock" : "hourglass"
            headline = "\(Strings.leaves) \(show(departure))"
            detail = minutes < 1 ? Strings.noWait : "\(ScheduleFormat.duration(minutes: minutes)) \(Strings.wait)"
            secondLine = arrivalText
            buttonReason = isReady ? nil : status.availableFrom.map { "\(Strings.availableFrom) \(show($0))" }
            let waitSpoken = minutes < 1
                ? SpokenStrings.noWait
                : "\(ScheduleFormat.spokenDuration(minutes: minutes)) \(SpokenStrings.minuteWait)."
            let availableSpoken = isReady ? "" : status.availableFrom.map {
                " \(Strings.availableFrom) \(speak($0))."
            } ?? ""
            self.spoken = "\(Strings.leaves) \(SpokenStrings.at) \(speak(departure)). \(waitSpoken)\(availableSpoken)"
                + " \(Strings.arriveBy) \(status.arrival.map(speak) ?? "")."
            legHeadline = status.legArrival.map {
                "\(Strings.leaves) \(show(departure))\(Strings.separator)\(Strings.arrives) \(show($0))"
            } ?? "\(Strings.leaves) \(show(departure))"
        case .noMoreToday:
            symbol = "moon"
            headline = Strings.noMoreToday
            detail = nil
            secondLine = nil
            buttonReason = nextText
            spoken = "\(Strings.noMoreToday). \(nextSpoken)"
            legHeadline = nextText
        case .noServiceToday:
            symbol = "calendar.badge.minus"
            headline = Strings.noTripsToday
            detail = status.note
            secondLine = nextText
            buttonReason = Strings.noTripsToday
            spoken = "\(Strings.noTripsToday)\(status.note.map { ", \($0)" } ?? ""). \(nextSpoken)"
            legHeadline = nextText
        }

        announcement = "\(SpokenStrings.routeAvailable) \(status.mode.displayName) \(SpokenStrings.leavesAt)"
            + " \(status.departure.map(speak) ?? "")."
        let said = status.todayTrips.map { trip -> String in
            switch trip.role {
            case .left: "\(speak(trip.time)), \(Strings.left)"
            case .tooSoon: "\(speak(trip.time)), \(Strings.tooSoon)"
            case .next: "\(speak(trip.time)), \(Strings.next)"
            case .later: speak(trip.time)
            }
        }
        tripsSpoken = "\(Strings.tripTimesToday) \(said.isEmpty ? Strings.none : said.joined(separator: "; "))."
            + (status.nextTrip == nil ? "" : " \(nextSpoken)")
    }
}

// MARK: - Callout Copy

extension ScheduleCopy {
    /// Short reason that replaces the duration on a map callout. Nil while the route is ready.
    static func calloutReason(for status: ScheduleStatus, uses24HourTime: Bool) -> String? {
        let show = { (date: Date) in ScheduleFormat.time(date, uses24HourTime: uses24HourTime) }
        switch status.state {
        case .ready:
            return nil
        case .tooEarly:
            return "\(Strings.leaves) \(status.departure.map(show) ?? "")"
        case .noMoreToday:
            return status.nextTrip.map { "Next \(ScheduleFormat.day($0)) \(show($0))" } ?? Strings.noUpcoming
        case .noServiceToday:
            return Strings.noTripsToday
        }
    }
}
