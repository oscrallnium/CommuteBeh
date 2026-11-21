//
//  ServiceTimetable.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import Foundation

/// How a schedule row or exception describes service. The raw value is the backend string.
nonisolated enum ServiceKind: String, Codable, Sendable {
    case window
    case departures
    case noService = "no_service"
}

/// One regular timetable row of a line. A nil `direction` covers both directions.
nonisolated struct ServiceScheduleRule: Codable, Sendable {
    var direction: String?
    var kind: ServiceKind
    var departures: [String]?
    var start: String?
    var end: String?
    var note: String?
    var days: [String]?
}

/// A dated override of a line's regular rows. `from` and `to` are inclusive "yyyy-MM-dd" dates.
nonisolated struct ServiceScheduleException: Codable, Sendable {
    var id: String?
    var direction: String?
    var kind: ServiceKind
    var departures: [String]?
    var start: String?
    var end: String?
    var note: String?
    var from: String
    var to: String
}

/// The service of one line, in one direction, on one calendar day.
nonisolated enum DayService: Equatable, Sendable {
    case unrestricted
    case noService(note: String?)
    /// Minutes after midnight. `endMinute < startMinute` means the window crosses midnight.
    case window(startMinute: Int, endMinute: Int)
    /// Sorted minutes after midnight.
    case departures([Int])
}

/// Pure timetable lookups. All date math uses the Asia/Manila calendar.
nonisolated struct ServiceTimetable: Sendable {

    private enum Config {
        static let timeZoneID = "Asia/Manila"
        static let lookAheadDays = 7
        static let weekdayCodes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    }

    private struct Entry {
        let direction: String?
        let kind: ServiceKind
        let departures: [Int]
        let start: Int?
        let end: Int?
        let note: String?
        let days: Set<String>?
        let from: String?
        let to: String?
    }

    let maxWaitMinutes: Int
    private let regular: [String: [Entry]]
    private let exceptions: [String: [Entry]]
    private let calendar: Calendar

    init(schedules: [String: [ServiceScheduleRule]] = [:],
         exceptions: [String: [ServiceScheduleException]] = [:],
         maxWaitMinutes: Int = 60) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: Config.timeZoneID) ?? .current
        self.calendar = calendar
        self.maxWaitMinutes = maxWaitMinutes
        self.regular = schedules.mapValues { rules in
            rules.map { Entry(direction: $0.direction, kind: $0.kind,
                              departures: Self.minutes($0.departures), start: Self.minute($0.start),
                              end: Self.minute($0.end), note: $0.note,
                              days: $0.days.map(Set.init), from: nil, to: nil) }
        }
        self.exceptions = exceptions.mapValues { items in
            items.map { Entry(direction: $0.direction, kind: $0.kind,
                              departures: Self.minutes($0.departures), start: Self.minute($0.start),
                              end: Self.minute($0.end), note: $0.note,
                              days: nil, from: $0.from, to: $0.to) }
        }
    }

    init(graph: TransitGraph) {
        self.init(schedules: graph.serviceSchedules, exceptions: graph.serviceScheduleExceptions,
                  maxWaitMinutes: graph.scheduledMaxWaitMinutes)
    }

    func hasTimetable(line: String) -> Bool {
        !(regular[line]?.isEmpty ?? true)
    }

    /// Exceptions that cover the date replace the regular rows of the line.
    func service(line: String, direction: String?, on date: Date) -> DayService {
        let key = dateKey(date)
        let overrides = (exceptions[line] ?? []).filter {
            ($0.from ?? "") <= key && key <= ($0.to ?? "") && applies($0, to: direction)
        }
        if !overrides.isEmpty { return resolve(overrides, direction: direction) }

        let rows = (regular[line] ?? []).filter { applies($0, to: direction) }
        if rows.isEmpty { return .unrestricted }
        let code = Config.weekdayCodes[calendar.component(.weekday, from: date) - 1]
        let today = rows.filter { $0.days?.contains(code) ?? true }
        return today.isEmpty ? .noService(note: nil) : resolve(today, direction: direction)
    }

    /// The first departure at or after `date`, within the look-ahead days.
    func nextDeparture(line: String, direction: String?, atOrAfter date: Date) -> Date? {
        let firstDay = calendar.startOfDay(for: date)
        for offset in 0...Config.lookAheadDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            switch service(line: line, direction: direction, on: day) {
            case .unrestricted:
                return date
            case .noService:
                continue
            case .departures(let list):
                if let found = list.lazy.map({ time(minute: $0, on: day) }).first(where: { $0 >= date }) {
                    return found
                }
            case .window(let start, _):
                if offset == 0, isRunning(line: line, direction: direction, at: date) { return date }
                let open = time(minute: start, on: day)
                if open >= date { return open }
            }
        }
        return nil
    }

    /// The departure times of the calendar day that holds `date`. Empty unless the day lists departures.
    func departures(line: String, direction: String?, on date: Date) -> [Date] {
        guard case .departures(let list) = service(line: line, direction: direction, on: date) else { return [] }
        let day = calendar.startOfDay(for: date)
        return list.map { time(minute: $0, on: day) }
    }

    /// True when the line serves `date`. A departures day counts as running; the engine adds the wait.
    func isRunning(line: String, direction: String?, at date: Date) -> Bool {
        let minute = minuteOfDay(date)
        switch service(line: line, direction: direction, on: date) {
        case .unrestricted, .departures:
            return true
        case .noService:
            break
        case .window(let start, let end):
            if end >= start ? (minute >= start && minute < end) : minute >= start { return true }
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date),
              case .window(let start, let end) = service(line: line, direction: direction, on: yesterday)
        else { return false }
        return end < start && minute < end
    }

    // MARK: - Helpers

    private func applies(_ entry: Entry, to direction: String?) -> Bool {
        entry.direction == nil || direction == nil || entry.direction == direction
    }

    /// A direction-specific entry wins over a direction-less one. No service wins over times.
    private func resolve(_ entries: [Entry], direction: String?) -> DayService {
        let specific = entries.filter { $0.direction != nil && $0.direction == direction }
        let chosen = specific.isEmpty ? entries : specific
        if let closed = chosen.first(where: { $0.kind == .noService }) { return .noService(note: closed.note) }
        let times = chosen.filter { $0.kind == .departures }.flatMap(\.departures)
        if !times.isEmpty { return .departures(Array(Set(times)).sorted()) }
        if let open = chosen.first(where: { $0.kind == .window && $0.start != nil && $0.end != nil }),
           let start = open.start, let end = open.end {
            return .window(startMinute: start, endMinute: end)
        }
        return .noService(note: nil)
    }

    private func dateKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func time(minute: Int, on day: Date) -> Date {
        calendar.date(byAdding: .minute, value: minute, to: day) ?? day
    }

    private static func minute(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func minutes(_ texts: [String]?) -> [Int] {
        (texts ?? []).compactMap(minute)
    }
}
