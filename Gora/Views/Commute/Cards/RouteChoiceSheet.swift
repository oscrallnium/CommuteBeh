//
//  RouteChoiceSheet.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Route Choice Sheet

/// Liquid Glass bottom sheet that shows the selected route option and starts Commute Mode.
/// The map owns route selection; this sheet only reads `selectedID`.
struct RouteChoiceSheet: View {
    let options: [RouteOption]
    @Binding var selectedID: RouteOption.ID?
    @Binding var isDetailExpanded: Bool
    /// False until the user is within 500 m of the route origin. The sheet then shows a hint
    /// in place of the "Use This Route" button.
    let canStartCommute: Bool
    let onUse: (RouteOption) -> Void
    /// The color the map draws a leg in.
    let legColor: (RouteLeg) -> Color

    private var option: RouteOption? {
        options.first { $0.id == selectedID } ?? options.first
    }

    var body: some View {
        if let option {
            let summary = RouteCardSummary(result: option.result, legColor: legColor)
            sheet(option: option, summary: summary)
        }
    }

    private func sheet(option: RouteOption, summary: RouteCardSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            grabber
            summaryBlock(option: option, summary: summary)
            legChips(summary.legRows)
            if isDetailExpanded {
                RouteChoiceLegList(legRows: summary.legRows)
                    .transition(.opacity)
            }
            actionRow(option: option)
        }
        .padding(.horizontal, DesignTokens.Space.xl)
        .padding(.top, DesignTokens.Space.s)
        .padding(.bottom, DesignTokens.Space.l)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Radius.routeSheet))
        .animation(DesignTokens.Motion.morph, value: isDetailExpanded)
    }

    // MARK: Header

    private var grabber: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.indicator)
            .fill(Color.faint)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
    }

    private func summaryBlock(option: RouteOption, summary: RouteCardSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            header(option: option)
            metrics(summary: summary)
            Text("Arrive by \(summary.arrivalTime) \(summary.arrivalPeriod) · \(summary.transfersText)")
                .font(DesignTokens.TypeScale.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func header(option: RouteOption) -> some View {
        HStack {
            Spacer()
            badge(for: option.label)
        }
    }

    @ViewBuilder
    private func badge(for label: RouteOption.Label) -> some View {
        switch label {
        case .fastest:  badgeText("Fastest", symbol: "bolt.fill")
        case .cheapest: badgeText("Cheapest", symbol: "pesosign.circle.fill")
        case .balanced: EmptyView()
        }
    }

    private func badgeText(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(DesignTokens.TypeScale.subtitleEmphasis)
            .foregroundStyle(Color.onyx)
            .padding(.horizontal, DesignTokens.Space.s)
            .padding(.vertical, DesignTokens.Space.xxs)
            .background(Color.haze,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.badge))
    }

    /// Ride modes in order, such as "Train, then Bus". Consecutive repeats collapse.
    private func modeSequence(_ result: RouteResult) -> String {
        var modes: [TransportMode] = []
        for leg in result.legs where leg.mode != .walk && modes.last != leg.mode {
            modes.append(leg.mode)
        }
        return modes.map { $0.rawValue.capitalized }.joined(separator: ", then ")
    }

    // MARK: Metrics

    private func metrics(summary: RouteCardSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xs) {
                ForEach(summary.durationParts, id: \.self) { part in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xxs) {
                        Text(part.value)
                            .font(DesignTokens.TypeScale.display)
                        Text(part.unit)
                            .font(DesignTokens.TypeScale.instruction)
                    }
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: DesignTokens.Space.s)
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xxs) {
                Text("₱\(summary.fareText)")
                    .font(DesignTokens.TypeScale.statValue)
                    .monospacedDigit()
                Text("fare")
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }

    // MARK: Leg chips

    private func legChips(_ rows: [RouteCardSummary.LegRow]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignTokens.Space.xs) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    chip(row)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ row: RouteCardSummary.LegRow) -> some View {
        Label(row.minutesText, systemImage: row.isWalk ? TransportMode.walk.icon : row.mode.icon)
            .font(DesignTokens.TypeScale.subtitleEmphasis)
            .padding(.horizontal, DesignTokens.Space.s)
            .frame(height: 28)
            .background(Color.haze,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.badge, style: .continuous))
    }

    // MARK: Actions

    private func actionRow(option: RouteOption) -> some View {
        HStack(spacing: DesignTokens.Space.sm) {
            detailsButton
            if canStartCommute {
                useButton(option: option)
            } else {
                startHint
            }
        }
    }

    private var detailsButton: some View {
        Button {
            isDetailExpanded.toggle()
        } label: {
            Image(systemName: isDetailExpanded ? "chevron.down.2" : "chevron.up.2")
                .font(.body.weight(.semibold))
                .symbolEffect(.pulse, options: .repeat(.continuous))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: 50, height: 50)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(isDetailExpanded ? "Hide route details" : "Show route details")
    }

    private func useButton(option: RouteOption) -> some View {
        Button {
            onUse(option)
        } label: {
            Text("Use This Route")
                .font(DesignTokens.TypeScale.controlLabel)
                .foregroundStyle(Color.licorice)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tangerine).interactive(), in: .capsule)
    }

    private var startHint: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Image(systemName: "location.slash")
                .font(DesignTokens.TypeScale.subtitle)
            Text("Go to the starting point to begin")
                .font(DesignTokens.TypeScale.subtitle)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }
}

// MARK: - Preview

#if DEBUG
private func previewStation(_ id: String, _ name: String, line: String, type: String) -> Station {
    Station(
        id: id, name: name, shortName: name, line: line, type: type,
        coordinates: Coordinates(lat: 14.5763, lng: 121.0194),
        isTerminal: false, isInterchange: false, interchangesWith: nil, amenities: [],
        operatingHours: .init(open: "05:30", close: "23:00"), accessPoints: nil, sequence: nil, boarding: nil
    )
}

private func previewLeg(
    _ from: Station, _ to: Station, mode: TransportMode, line: String,
    minutes: Double, fare: Double, instruction: String
) -> RouteLeg {
    RouteLeg(
        fromStation: from, toStation: to, mode: mode, line: line, direction: nil,
        stops: [from, to], effectiveTravelMinutes: minutes, fare: fare, distanceKm: 3,
        polylineCoordinates: [], estimatedArrival: Date().addingTimeInterval(minutes * 60),
        instruction: instruction, rawSteps: []
    )
}

private func previewOptions() -> [RouteOption] {
    let dela = previewStation("BUS_DELA_ROSA", "Dela Rosa", line: "EDSA_BUS", type: "bus")
    let gil = previewStation("LRT1_GIL", "Gil Puyat", line: "LRT-1", type: "train")
    let buendia = previewStation("LRT1_BUENDIA", "LRT Buendia", line: "LRT-1", type: "train")
    let legs = [
        previewLeg(dela, dela, mode: .walk, line: "ACCESS_WALK", minutes: 8, fare: 0,
                   instruction: "Walk to Dela Rosa"),
        previewLeg(dela, gil, mode: .bus, line: "EDSA_BUS", minutes: 18, fare: 22,
                   instruction: "Ride the bus northbound"),
        previewLeg(gil, buendia, mode: .train, line: "LRT-1", minutes: 12, fare: 26,
                   instruction: "LRT-1 southbound"),
    ]
    let result = RouteResult(legs: legs, totalTimeMinutes: 38, totalFare: 48,
                             totalDistanceKm: 9, transfers: 1, modes: [.bus, .train])
    return [RouteOption(result: result, label: .fastest)]
}

private struct RouteChoiceSheetPreview: View {
    @State private var selected: RouteOption.ID?
    @State var expanded: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            RouteChoiceSheet(options: previewOptions(), selectedID: $selected,
                             isDetailExpanded: $expanded, canStartCommute: true,
                             onUse: { _ in }, legColor: { $0.mode.color })
                .padding(.horizontal, DesignTokens.Space.sm)
        }
    }
}

#Preview("Route Choice Sheet · light") {
    RouteChoiceSheetPreview(expanded: true).preferredColorScheme(.light)
}

#Preview("Route Choice Sheet · dark") {
    RouteChoiceSheetPreview(expanded: true).preferredColorScheme(.dark)
}

#Preview("Route Choice Sheet · collapsed") {
    RouteChoiceSheetPreview(expanded: false)
}
#endif
