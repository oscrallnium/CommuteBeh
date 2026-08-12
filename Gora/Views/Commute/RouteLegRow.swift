//
//  RouteLegRow.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 8/10/26.
//

import SwiftUI

// MARK: - Route Leg Row

/// One user-facing `RouteLeg`: a single boarding through a single alighting, with the
/// intermediate stops expandable.
struct RouteLegRow: View {
    let leg: RouteLeg
    @State private var stopsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Main leg row ─────────────────────────────────────────────────
            HStack(alignment: .top, spacing: DesignTokens.Space.s3) {
                // Mode indicator. Ride legs show their mode icon in the mode colour and walk
                // legs show a gray figure, so a transfer reads as an icon change down the list.
                Image(systemName: leg.mode.icon)
                    .font(.caption)
                    .foregroundStyle(leg.mode.color)
                    .frame(width: 26, height: 26)
                    .background(leg.mode.color.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(leg.instruction)
                        .font(DesignTokens.TypeScale.cardTitle)

                    // A walk past what that stop's role justifies (see AccessPolicy) is
                    // still offered — but never silently. The badge makes the trade-off
                    // the passenger is being asked to accept explicit.
                    if leg.isLongAccessWalk {
                        Label("Long walk · \(walkDistanceLabel)", systemImage: "figure.walk.motion")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(DesignTokens.Colors.warning)
                    }

                    HStack(spacing: DesignTokens.Space.s2) {
                        // Time
                        Label("\(Int(leg.effectiveTravelMinutes)) min", systemImage: "clock")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        // Fare (walk legs have zero fare — hide chip)
                        if leg.fare > 0 {
                            Text("•")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                            Label("₱\(String(format: "%.0f", leg.fare))", systemImage: "banknote")
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        // Estimated arrival
                        Text("•")
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                        Text(arrivalString)
                            .font(DesignTokens.TypeScale.meta)
                            .foregroundStyle(.secondary)
                    }

                    // Intermediate stops disclosure — only shown when there are stops to expand
                    if leg.stopCount > 1 {
                        Button {
                            withAnimation(DesignTokens.Motion.disclose) {
                                stopsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: DesignTokens.Space.s1) {
                                Text(stopsExpanded
                                     ? "Hide stops"
                                     : "\(leg.stopCount) stop\(leg.stopCount > 1 ? "s" : "")")
                                    .font(DesignTokens.TypeScale.meta)
                                    .foregroundStyle(leg.mode.color)
                                Image(systemName: stopsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(leg.mode.color)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)

            // ── Expandable intermediate stop list ────────────────────────────
            if stopsExpanded && leg.stops.count > 2 {
                let intermediate = leg.stops.dropFirst().dropLast()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(intermediate.enumerated()), id: \.offset) { _, station in
                        HStack(spacing: DesignTokens.Space.s3) {
                            // Vertical track line + small dot
                            ZStack {
                                Rectangle()
                                    .fill(leg.mode.color.opacity(0.35))
                                    .frame(width: 2)
                                Circle()
                                    .fill(leg.mode.color.opacity(0.6))
                                    .frame(width: 6, height: 6)
                            }
                            .frame(width: 10)
                            .padding(.leading, 2)

                            Text(station.name)
                                .font(DesignTokens.TypeScale.meta)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, DesignTokens.Space.s1)
                    }
                }
                .padding(.leading, 38) // align under leg text (26 pt icon + 12 pt gap)
                .transition(.opacity.combined(with: .move(edge: .top))) // motion.disclose
            }
        }
    }

    /// Shared instance — building a `DateFormatter` per body evaluation showed up
    /// while scrolling the leg list. Formatting off a shared instance is thread-safe.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var arrivalString: String {
        Self.timeFormatter.string(from: leg.estimatedArrival)
    }

    /// Walk distance in the same units the out-of-range error uses — metres under a
    /// kilometre, so "900 m" never shows up as "0.9 km".
    private var walkDistanceLabel: String {
        leg.distanceKm < 1
            ? "\(Int((leg.distanceKm * 1000).rounded(.toNearestOrAwayFromZero) / 10) * 10) m"
            : String(format: "%.1f km", leg.distanceKm)
    }
}

// MARK: - Preview Helpers

#if DEBUG
private extension Station {
    static func mock(
        id: String, name: String, shortName: String,
        line: String, type: String,
        lat: Double = 14.5763, lng: Double = 121.0194
    ) -> Station {
        Station(
            id: id, name: name, shortName: shortName,
            line: line, type: type,
            coordinates: Coordinates(lat: lat, lng: lng),
            isTerminal: false, isInterchange: false,
            interchangesWith: nil, amenities: [],
            operatingHours: .init(open: "05:30", close: "23:00"),
            accessPoints: nil
        )
    }
}

private extension RouteLeg {
    static func mock(
        from: Station, to: Station,
        mode: TransportMode, line: String,
        direction: String? = nil,
        stops: [Station]? = nil,
        minutes: Double, fare: Double, distanceKm: Double = 3,
        instruction: String,
        arrival: Date = Date().addingTimeInterval(1800)
    ) -> RouteLeg {
        RouteLeg(
            fromStation: from, toStation: to,
            mode: mode, line: line, direction: direction,
            stops: stops ?? [from, to],
            effectiveTravelMinutes: minutes,
            fare: fare, distanceKm: distanceKm,
            polylineCoordinates: [],
            estimatedArrival: arrival,
            instruction: instruction,
            rawSteps: []
        )
    }
}
#endif

// MARK: - Previews

#Preview("Search Suggestions") {
    let stations: [Station] = [
        .mock(id: "MRT3_AYALA",    name: "Ayala Station",          shortName: "Ayala",       line: "MRT-3",          type: "train"),
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",         shortName: "Buendia",     line: "MRT-3",          type: "train"),
        .mock(id: "LRT1_GIL",     name: "Gil Puyat Station",       shortName: "Gil Puyat",   line: "LRT-1",          type: "train"),
        .mock(id: "BUS_AYALA",    name: "Ayala EDSA Bus Stop",     shortName: "Ayala Bus",   line: "EDSA_BUS",       type: "bus"),
        .mock(id: "JEEP_BGC",     name: "Ayala BGC Gate",          shortName: "BGC Ayala",   line: "EJEEPNEY_BGC",   type: "jeepney"),
    ]
    VStack {
        Text("\"Ayala\" results")
            .font(DesignTokens.TypeScale.meta)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        SuggestionList(suggestions: stations.map(LocationSuggestion.station)) { _ in }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .cardShadow(y: 4)
            .padding(.horizontal)
        Spacer()
    }
    .padding(.top)
    .background(Color(.systemGroupedBackground))
}

#Preview("Route Results Panel") {
    @Previewable @Namespace var previewNS
    let ayala   = Station.mock(id: "MRT3_AYALA",    name: "Ayala Station",    shortName: "Ayala",      line: "MRT-3", type: "train")
    let kalaw   = Station.mock(id: "MRT3_KALAW",    name: "Kalaw Station",    shortName: "Kalaw",      line: "MRT-3", type: "train")
    let central = Station.mock(id: "LRT1_CENTRAL",  name: "Central Station",  shortName: "Central",    line: "LRT-1", type: "train")
    let avenida = Station.mock(id: "LRT1_AVENIDA",  name: "Avenida Station",  shortName: "Avenida",    line: "LRT-1", type: "train")
    let carriedo = Station.mock(id: "LRT1_CARRIEDO", name: "Carriedo Station", shortName: "Carriedo",  line: "LRT-1", type: "train")

    let mrt3Stops: [Station] = [
        ayala,
        .mock(id: "MRT3_BUENDIA",  name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",     name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        kalaw,
    ]
    let lrt1Stops: [Station] = [central, carriedo, avenida]

    let fastestLegs: [RouteLeg] = [
        .mock(from: ayala,   to: kalaw,   mode: .train, line: "MRT-3", direction: "southbound",
              stops: mrt3Stops, minutes: 12, fare: 28, distanceKm: 4.1,
              instruction: "Ride MRT-3 Southbound to Kalaw",
              arrival: Date().addingTimeInterval(720)),
        .mock(from: kalaw,   to: central, mode: .walk,  line: "walk",
              minutes: 5, fare: 0, distanceKm: 0.4,
              instruction: "Walk to LRT-1 Central Station",
              arrival: Date().addingTimeInterval(1020)),
        .mock(from: central, to: avenida, mode: .train, line: "LRT-1",
              stops: lrt1Stops, minutes: 8, fare: 20, distanceKm: 2.9,
              instruction: "Ride LRT-1 Northbound to Avenida",
              arrival: Date().addingTimeInterval(1500)),
    ]
    let cheapestLegs: [RouteLeg] = [
        .mock(from: ayala, to: avenida, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
              minutes: 48, fare: 15, distanceKm: 9.2,
              instruction: "Ride Jeepney to Avenida",
              arrival: Date().addingTimeInterval(2880)),
    ]

    let fastest  = RouteResult(legs: fastestLegs,  totalTimeMinutes: 25, totalFare: 48,  totalDistanceKm: 7.4, transfers: 2, modes: [.train, .train])
    let cheapest = RouteResult(legs: cheapestLegs, totalTimeMinutes: 48, totalFare: 15,  totalDistanceKm: 9.2, transfers: 0, modes: [.jeepney])

    let options: [RouteOption] = [
        RouteOption(result: fastest,  label: .fastest),
        RouteOption(result: cheapest, label: .cheapest),
    ]

    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        RouteResultsPanel(options: options, morphNS: previewNS, onSelect: { _ in }, onPreview: { _ in }).padding()
    }
}

#Preview("Route Leg Row – Train") {
    let from = Station.mock(id: "MRT3_AYALA",   name: "Ayala Station",    shortName: "Ayala",    line: "MRT-3", type: "train")
    let to   = Station.mock(id: "MRT3_KALAW",   name: "Kalaw Station",    shortName: "Kalaw",    line: "MRT-3", type: "train")
    let stops: [Station] = [
        from,
        .mock(id: "MRT3_BUENDIA", name: "Buendia Station",  shortName: "Buendia",  line: "MRT-3", type: "train"),
        .mock(id: "MRT3_VITO",    name: "Vito Cruz Station", shortName: "Vito Cruz",line: "MRT-3", type: "train"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .train, line: "MRT-3",
                            direction: "southbound", stops: stops,
                            minutes: 12, fare: 28, distanceKm: 4.1,
                            instruction: "Ride MRT-3 Southbound to Kalaw")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Walk") {
    let from = Station.mock(id: "MRT3_KALAW",  name: "Kalaw Station",   shortName: "Kalaw",  line: "MRT-3", type: "train")
    let to   = Station.mock(id: "LRT1_CENTRAL",name: "Central Station", shortName: "Central",line: "LRT-1", type: "train")
    let leg  = RouteLeg.mock(from: from, to: to, mode: .walk, line: "walk",
                             minutes: 5, fare: 0, distanceKm: 0.4,
                             instruction: "Walk to LRT-1 Central Station")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview("Route Leg Row – Jeepney") {
    let from = Station.mock(id: "JEEP_QUIAPO", name: "Quiapo Church",  shortName: "Quiapo", line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let to   = Station.mock(id: "JEEP_CUBAO",  name: "Cubao Terminal", shortName: "Cubao",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney")
    let stops: [Station] = [
        from,
        .mock(id: "JEEP_STA_MESA", name: "Sta. Mesa",     shortName: "Sta. Mesa",  line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        .mock(id: "JEEP_ESPANA",   name: "España Blvd.",  shortName: "España",     line: "JEEPNEY_QUIAPO_CUBAO", type: "jeepney"),
        to,
    ]
    let leg = RouteLeg.mock(from: from, to: to, mode: .jeepney, line: "JEEPNEY_QUIAPO_CUBAO",
                            stops: stops, minutes: 22, fare: 14, distanceKm: 6.8,
                            instruction: "Ride Jeepney (Quiapo–Cubao) to Cubao Terminal")
    List { RouteLegRow(leg: leg) }.listStyle(.plain)
}

#Preview {
    ContentView()
}
