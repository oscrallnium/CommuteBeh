//
//  RouteCardSummary.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

// MARK: - Route Card Summary

/// Every display string a result card needs, derived once per `RouteOption` rather than on
/// every body evaluation. `payments` scans every `rawStep` of every leg, so deriving these
/// inline costs O(legs x rawSteps) per animation frame, per card.
struct RouteCardSummary {
    struct LegRow: Identifiable {
        let id: UUID
        let title: String
        let subtitle: String
        let minutesText: String
        let mode: TransportMode
        let isWalk: Bool
        let color: Color
        /// The lines of the leg's own mode: the chosen line first, then the alternatives.
        /// Empty for a walk leg.
        let lines: [LineOption]
        /// The lines of the other modes that stop at the same boarding and get-off stops.
        let otherModeSections: [ModeSection]
        var isGrouped: Bool { lines.count + otherModeSections.reduce(0) { $0 + $1.lines.count } > 1 }
        /// "2 jeepneys, 1 bus also stop here", or nil when no other mode stops here.
        var otherModesSpoken: String? {
            guard !otherModeSections.isEmpty else { return nil }
            return "\(otherModeSections.map(\.countText).formatted(.list(type: .and))) \(RouteCardSummary.alsoStopHere)"
        }
    }

    /// The lines of one other mode on a grouped leg.
    struct ModeSection: Identifiable {
        let mode: TransportMode
        /// "Jeepneys also stop here"
        let title: String
        /// "2 jeepneys"
        let countText: String
        let lines: [LineOption]
        var id: TransportMode { mode }
    }

    /// One line a passenger can ride between the stops of a ride leg.
    struct LineOption: Identifiable {
        let id: String
        let name: String
        /// "₱15", or nil when the line has no fare.
        let fareText: String?
        let payments: [String]
        let isAirConditioned: Bool
        let mode: TransportMode
        /// Ride minutes minus the chosen ride minutes, rounded. Nil for a line of the leg's own mode.
        let minutesDelta: Int?
    }

    /// The lines of one ride leg, split by mode.
    private struct LegLines {
        let sameMode: [LineOption]
        let otherModes: [LineOption]
    }

    /// One ride leg as the collapsed route list shows it.
    struct RideRow: Identifiable {
        let id: UUID
        let title: String
        let minutes: Int
        let mode: TransportMode
        let color: Color
    }

    /// One number and its unit — "2" + "hr". Split so the metric row can set the
    /// numeral large and the unit small, which a single formatted string cannot do.
    struct MetricPart: Hashable {
        let value: String
        let unit: String
    }

    /// "2 hours, 32 minutes" — the whole-sentence form, for the compact row and the
    /// detail header where the metric reads as prose.
    let durationText: String
    /// The same duration split for the card's metric row: `[2 hr, 32 min]`.
    let durationParts: [MetricPart]
    /// "2:48" — clock time without the period, so the period can be set smaller.
    let arrivalTime: String
    /// "PM", or empty in 24-hour time.
    let arrivalPeriod: String
    /// "Arrive at 2:48 PM"
    let arriveText: String
    /// "47" — rendered next to a separate ₱ glyph so the two can scale apart.
    let fareText: String
    /// "1 transfer · 7 mins walking"
    let statsText: String
    /// "2 transfers" / "Direct"
    let transfersText: String
    /// Payment IDs accepted across every ride leg.
    let payments: [String]
    /// Payment IDs that every line of every ride leg accepts.
    let paymentsFull: [String]
    /// Payment IDs that only some lines accept.
    let paymentsPartial: [String]
    let legRows: [LegRow]
    let rideRows: [RideRow]
    /// Total minutes of every walk leg, or nil when the route has no walk.
    let walkMinutes: Int?

    private enum Strings {
        static let rideAny = "Ride any of"
        static let any = "Any of"
        static let board = "Board at"
        static let getOff = "Get off at"
        static let from = "from"
        static let to = "to"
        static let at = "at"
        static let hour = "hour"
        static let hours = "hours"
        static let minute = "min"
        static let minutes = "mins"
    }

    private enum Time {
        static let minutesPerHour = 60
    }

    static let alsoStopHere = "also stop here"

    private static let interchangeLine = "INTERCHANGE"

    private enum ClockFormat {
        static let full12 = "h:mm a"
        static let clock12 = "h:mm"
        static let period12 = "a"
        static let clock24 = "HH:mm"
        static let locale = "en_US_POSIX"
    }

    /// Each style keeps one shared formatter. The POSIX locale makes the fixed format exact,
    /// whatever the phone's 12/24-hour setting is.
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: ClockFormat.locale)
        return f
    }

    private static let fullFormatter12 = makeFormatter(ClockFormat.full12)
    private static let clockFormatter12 = makeFormatter(ClockFormat.clock12)
    private static let periodFormatter12 = makeFormatter(ClockFormat.period12)
    private static let clockFormatter24 = makeFormatter(ClockFormat.clock24)

    /// `legColor` gives each leg row the color the map draws that leg in.
    /// `uses24HourTime` picks the clock style: "13:24", or "1:24" with the period "PM".
    /// `lineName` and `modePlural` read the graph; their defaults show the line key and the mode name.
    init(result: RouteResult, uses24HourTime: Bool, legColor: (RouteLeg) -> Color = { $0.mode.color },
         lineName: (String) -> String = { $0 },
         modePlural: (TransportMode) -> String = { $0.displayName },
         includesOtherModes: Bool = true) {
        let shownMinutes = Self.shownMinutes(result)
        durationText = Self.durationLabel(minutes: shownMinutes)
        durationParts = Self.durationParts(minutes: shownMinutes)
        fareText = FareText.amount(result.totalFare)

        let arrival = result.legs.last?.estimatedArrival
        let clockFormatter = uses24HourTime ? Self.clockFormatter24 : Self.clockFormatter12
        let fullFormatter = uses24HourTime ? Self.clockFormatter24 : Self.fullFormatter12
        let arrivalString = arrival.map { fullFormatter.string(from: $0) } ?? ""
        arriveText = arrivalString.isEmpty ? "" : "Arrive at \(arrivalString)"
        arrivalTime = arrival.map { clockFormatter.string(from: $0) } ?? ""
        arrivalPeriod = arrival.map { uses24HourTime ? "" : Self.periodFormatter12.string(from: $0) } ?? ""

        let transfers = result.transfers
        transfersText = transfers == 0
            ? "Direct"
            : "\(transfers) transfer\(transfers > 1 ? "s" : "")"

        let walkMins = Int(result.legs
            .filter { $0.mode == .walk && $0.line != "ACCESS_WALK" }
            .reduce(0.0) { $0 + $1.effectiveTravelMinutes }
            .rounded())
        let walkPart = walkMins > 0
            ? " · \(walkMins) min\(walkMins == 1 ? "" : "s") walking"
            : ""
        statsText = transfersText + walkPart

        // Payments common to every ride leg — a payment method only helps if it
        // covers the whole trip.
        let rideLegs = result.legs.filter { $0.mode != .walk }
        if let firstRide = rideLegs.first {
            var common = Set(firstRide.rawSteps.flatMap { $0.edge.acceptedPayments })
            for leg in rideLegs.dropFirst() {
                common.formIntersection(Set(leg.rawSteps.flatMap { $0.edge.acceptedPayments }))
            }
            payments = common.sorted()
        } else {
            payments = []
        }

        let optionsByLeg = Dictionary(uniqueKeysWithValues: result.legs.map {
            ($0.id, Self.lineOptions(for: $0, lineName: lineName, includesOtherModes: includesOtherModes))
        })
        let lineSets = result.legs.flatMap { optionsByLeg[$0.id]?.sameMode ?? [] }.map { Set($0.payments) }
        let everyLine = lineSets.dropFirst().reduce(lineSets.first ?? []) { $0.intersection($1) }
        let anyLine = lineSets.reduce(into: Set<String>()) { $0.formUnion($1) }
        paymentsFull = everyLine.sorted()
        paymentsPartial = anyLine.subtracting(everyLine).sorted()

        walkMinutes = {
            let walks = result.legs.filter { $0.mode == .walk }
            guard !walks.isEmpty else { return nil }
            return Int(walks.reduce(0.0) { $0 + $1.effectiveTravelMinutes }.rounded())
        }()

        rideRows = result.legs.compactMap { leg in
            let options = optionsByLeg[leg.id]?.sameMode ?? []
            guard !options.isEmpty else { return nil }
            let title = options.count > 1
                ? "\(Strings.any) \(options.count) \(modePlural(leg.mode).lowercased())"
                : options[0].name
            return RideRow(id: leg.id, title: title, minutes: Int(leg.effectiveTravelMinutes.rounded()),
                           mode: leg.mode, color: legColor(leg))
        }

        legRows = result.legs.enumerated().map { index, leg in
            let isWalk = leg.mode == .walk || leg.line == Self.interchangeLine
            let options = optionsByLeg[leg.id]?.sameMode ?? []
            let others = optionsByLeg[leg.id]?.otherModes ?? []
            let title: String
            let subtitle: String
            let previousEnd = index > 0 ? result.legs[index - 1].toStation : nil
            let boardingStop = previousEnd?.id == leg.fromStation.id ? leg.fromStation.name : nil
            if options.count + others.count > 1 {
                title = options.count > 1
                    ? "\(Strings.rideAny) \(options.count) \(modePlural(leg.mode).lowercased())"
                    : leg.instruction
                subtitle = "\(Strings.board) \(leg.fromStation.name) · \(Strings.getOff) \(leg.toStation.name)"
            } else if isWalk {
                title = Self.omittingBoardingStop(leg.instruction, boardingStop)
                subtitle = Self.distanceLabel(leg.distanceKm)
            } else {
                title = Self.omittingBoardingStop(leg.instruction, boardingStop)
                let path = leg.stopCount > 1
                    ? "\(leg.stopCount) stops → \(leg.toStation.name)"
                    : "\(leg.fromStation.name) → \(leg.toStation.name)"
                subtitle = leg.fare > 0 ? "\(path) · \(FareText.pesos(leg.fare))" : path
            }
            return LegRow(
                id: leg.id,
                title: title,
                subtitle: subtitle,
                minutesText: Self.legDuration(minutes: Int(leg.effectiveTravelMinutes.rounded())),
                mode: leg.mode,
                isWalk: isWalk,
                color: legColor(leg),
                lines: options,
                otherModeSections: Self.modeSections(others, modePlural: modePlural)
            )
        }
    }

    /// Drops the boarding stop from an instruction when the row above already names it.
    /// Returns the instruction unchanged unless the stop appears exactly once in a known format.
    private static func omittingBoardingStop(_ instruction: String, _ stop: String?) -> String {
        guard let stop else { return instruction }
        let formats = [(" \(Strings.from) \(stop) \(Strings.to) ", " \(Strings.to) "),
                       (" \(Strings.at) \(stop),", ",")]
        for (match, replacement) in formats where instruction.components(separatedBy: match).count == 2 {
            return instruction.replacingOccurrences(of: match, with: replacement)
        }
        return instruction
    }

    /// The chosen line of a ride leg with its same-mode alternatives, and the lines of other modes.
    /// Both are empty for a walk or interchange leg.
    private static func lineOptions(for leg: RouteLeg, lineName: (String) -> String,
                                    includesOtherModes: Bool) -> LegLines {
        guard leg.mode != .walk, leg.line != interchangeLine else { return LegLines(sameMode: [], otherModes: []) }
        let chosen = LineOption(
            id: leg.line,
            name: lineName(leg.line),
            fareText: fareLabel(leg.fare),
            payments: Set(leg.rawSteps.flatMap { $0.edge.acceptedPayments }).sorted(),
            isAirConditioned: leg.rawSteps.first?.edge.isAirConditioned ?? false,
            mode: leg.mode,
            minutesDelta: nil)
        var sameMode = [chosen]
        var otherModes: [LineOption] = []
        for alternative in leg.alternativeLines {
            let mode = alternative.mode ?? leg.mode
            let isOtherMode = mode != leg.mode
            guard !isOtherMode || includesOtherModes else { continue }
            let option = LineOption(
                id: alternative.line, name: lineName(alternative.line), fareText: fareLabel(alternative.fare),
                payments: alternative.acceptedPayments.sorted(), isAirConditioned: alternative.isAirConditioned,
                mode: mode,
                minutesDelta: isOtherMode
                    ? Int((alternative.rideMinutes - leg.effectiveTravelMinutes).rounded()) : nil)
            if isOtherMode { otherModes.append(option) } else { sameMode.append(option) }
        }
        return LegLines(sameMode: sameMode, otherModes: otherModes)
    }

    /// One section per mode, in `TransportMode.allCases` order. A mode with no lines has no section.
    private static func modeSections(_ options: [LineOption],
                                     modePlural: (TransportMode) -> String) -> [ModeSection] {
        TransportMode.allCases.compactMap { mode in
            let lines = options.filter { $0.mode == mode }
            guard !lines.isEmpty else { return nil }
            let plural = modePlural(mode)
            let noun = lines.count == 1 ? mode.displayName.lowercased() : plural.lowercased()
            return ModeSection(mode: mode,
                               title: "\(plural.prefix(1).uppercased() + plural.dropFirst()) \(alsoStopHere)",
                               countText: "\(lines.count) \(noun)",
                               lines: lines)
        }
    }

    private static func fareLabel(_ fare: Double) -> String? {
        fare > 0 ? FareText.pesos(fare) : nil
    }

    /// A route with a timetable leg shows its ride minutes only: no walks and no wait.
    /// Every other route shows its total time.
    private static func shownMinutes(_ result: RouteResult) -> Double {
        guard result.hasTimetableLeg else { return result.totalTimeMinutes }
        return result.legs
            .filter { $0.mode != .walk }
            .reduce(0) { $0 + $1.effectiveTravelMinutes }
    }

    /// Total trip time as "1 hour, 12 minutes" rather than "72 minutes".
    /// `Duration`'s unit style handles pluralisation, a dropped zero remainder, the sub-hour
    /// case, and locale translation of both unit names and separator.
    private static func durationLabel(minutes: Double) -> String {
        let wholeMinutes = max(0, Int(minutes.rounded()))
        return Duration.seconds(wholeMinutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// The same duration as `durationLabel`, split into parts. Built directly rather than
    /// parsed back out of the formatted string, since either unit can be absent.
    private static func durationParts(minutes: Double) -> [MetricPart] {
        let wholeMinutes = max(0, Int(minutes.rounded()))
        let hours = wholeMinutes / 60
        let remainder = wholeMinutes % 60
        var parts: [MetricPart] = []
        if hours > 0 { parts.append(MetricPart(value: "\(hours)", unit: "hr")) }
        if remainder > 0 || hours == 0 {
            parts.append(MetricPart(value: "\(remainder)", unit: "min"))
        }
        return parts
    }

    /// The clock parts of `date`: "1:24" with the period "PM", or "13:24" with an empty period in 24-hour time.
    static func clockParts(_ date: Date, uses24HourTime: Bool) -> (time: String, period: String) {
        let clock = uses24HourTime ? clockFormatter24 : clockFormatter12
        return (clock.string(from: date), uses24HourTime ? "" : periodFormatter12.string(from: date))
    }

    /// Metres under a kilometre, rounded to 10 m — so "900 m" never reads "0.9 km".
    /// A leg time as "8 mins", "1 hour" or "1 hour 24 mins". Both leg lists show this text.
    static func legDuration(minutes: Int) -> String {
        let hours = minutes / Time.minutesPerHour
        let remainder = minutes % Time.minutesPerHour
        let minuteText = "\(remainder) \(remainder == 1 ? Strings.minute : Strings.minutes)"
        guard hours > 0 else { return minuteText }
        let hourText = "\(hours) \(hours == 1 ? Strings.hour : Strings.hours)"
        return remainder == 0 ? hourText : "\(hourText) \(minuteText)"
    }

    static func distanceLabel(_ km: Double) -> String {
        km < 1
            ? "\(Int((km * 1000).rounded(.toNearestOrAwayFromZero) / 10) * 10) m"
            : String(format: "%.1f km", km)
    }

    static func shortName(forPayment id: String) -> String {
        switch id {
        case "beep_card": return "Beep"
        case "cash":      return "Cash"
        case "gcash":     return "GCash"
        case "maya":      return "Maya"
        case "card":      return "Card"
        default:          return id.capitalized
        }
    }

    static func symbol(forPayment id: String) -> String {
        switch id {
        case "beep_card": return "payment.beep_card"
        case "cash":      return "banknote"
        case "gcash":     return "g.circle.fill"
        case "maya":      return "m.circle.fill"
        case "card":      return "creditcard"
        default:          return "banknote"
        }
    }
}
