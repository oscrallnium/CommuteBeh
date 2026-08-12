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
    /// "PM"
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
    let legRows: [LegRow]

    /// `DateFormatter` init is the expensive part (locale + format parsing); reading
    /// `string(from:)` on a shared instance is thread-safe and ~free.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Clock and period are formatted separately so the metric row can set "2:48"
    /// large and "PM" small — one string cannot carry two sizes.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()

    init(result: RouteResult) {
        durationText = Self.durationLabel(minutes: result.totalTimeMinutes)
        durationParts = Self.durationParts(minutes: result.totalTimeMinutes)
        fareText = "\(Int(result.totalFare))"

        let arrival = result.legs.last?.estimatedArrival
        let arrivalString = arrival.map { Self.timeFormatter.string(from: $0) } ?? ""
        arriveText = arrivalString.isEmpty ? "" : "Arrive at \(arrivalString)"
        arrivalTime = arrival.map { Self.clockFormatter.string(from: $0) } ?? ""
        arrivalPeriod = arrival.map { Self.periodFormatter.string(from: $0) } ?? ""

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

        legRows = result.legs.map { leg in
            let isWalk = leg.mode == .walk || leg.line == "INTERCHANGE"
            let subtitle: String
            if isWalk {
                subtitle = Self.distanceLabel(leg.distanceKm)
            } else {
                let path = leg.stopCount > 1
                    ? "\(leg.stopCount) stops → \(leg.toStation.shortName)"
                    : "\(leg.fromStation.shortName) → \(leg.toStation.shortName)"
                subtitle = leg.fare > 0 ? "\(path) · ₱\(Int(leg.fare))" : path
            }
            return LegRow(
                id: leg.id,
                title: leg.instruction,
                subtitle: subtitle,
                minutesText: "\(Int(leg.effectiveTravelMinutes.rounded())) min",
                mode: leg.mode,
                isWalk: isWalk
            )
        }
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

    /// Metres under a kilometre, rounded to 10 m — so "900 m" never reads "0.9 km".
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
        case "beep_card": return "creditcard.fill"
        case "cash":      return "banknote"
        case "gcash":     return "g.circle.fill"
        case "maya":      return "m.circle.fill"
        case "card":      return "creditcard"
        default:          return "banknote"
        }
    }
}
