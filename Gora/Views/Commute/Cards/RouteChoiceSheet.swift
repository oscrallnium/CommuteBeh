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
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false
    @AppStorage(SettingsKey.showOtherModes) private var showOtherModes = true
    @Environment(RouteStore.self) private var routeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var summaryCache = SummaryCache()

    private enum Layout {
        static let contentFadeOut: Animation = .easeOut(duration: 0.1)
        static let contentFadeIn: Animation = .easeOut(duration: 0.2).delay(0.1)
        static let fareTintOpacity = 0.18
        static let fareMinHeight: CGFloat = 30
        static let fareVerticalPadding = DesignTokens.Space.xs
        static let overlineSymbolSpacing = DesignTokens.Space.xs
        static let actionSpacing: CGFloat = 8
        static let labelSpacing: CGFloat = 8
        static let labelMotion: Animation = .easeInOut(duration: 0.32)
        static let labelMotionReduced: Animation = .easeInOut(duration: 0.15)
        static let offOpacity = 0.55
        static let reasonLines = 2
        static let readyFade: Animation = .easeInOut(duration: 0.24)
    }

    private enum Strings {
        static let fastest = "Fastest"
        static let balanced = "Balanced"
        static let cheapest = "Cheapest"
        static let fare = "fare"
        static let useRoute = "Use This Route"
        static let showDetails = "Show Route Details"
        static let showSummary = "Show Route Summary"
    }

    private var option: RouteOption? {
        options.first { $0.id == selectedID } ?? options.first
    }

    var body: some View {
        if let option {
            let summary = summaryCache.summary(for: option, uses24HourTime: use24HourTime,
                                               includesOtherModes: showOtherModes,
                                               graphVersion: routeStore.graphVersion) {
                RouteCardSummary(result: option.result, uses24HourTime: use24HourTime, legColor: legColor,
                                 lineName: routeStore.lineDisplayName,
                                 modePlural: routeStore.modePluralName,
                                 includesOtherModes: showOtherModes)
            }
            sheet(option: option, summary: summary)
        }
    }

    private func sheet(option: RouteOption, summary: RouteCardSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            grabber
            summaryBlock(option: option, summary: summary)
            if option.result.hasScheduledLeg {
                ScheduleTicker(result: option.result) { status in
                    if let status { ScheduleTripRow(status: status) }
                }
            }
            if isDetailExpanded {
                legList(option: option, summary: summary)
                    .transition(contentTransition)
            } else {
                RouteChoiceRideList(summary: summary, isDetailExpanded: $isDetailExpanded)
                    .transition(contentTransition)
            }
            actionRow(option: option)
        }
        .padding(.horizontal, DesignTokens.Space.xl)
        .padding(.top, DesignTokens.Space.s)
        .padding(.bottom, DesignTokens.Space.l)
        // The glass is a background layer, not a host. Content hosted inside a resizing glass view
        // is laid out from the glass's top edge, so the action row moves during the expand animation.
        .background {
            Color.clear
                .goraGlass(DesignTokens.Materials.routeSheetGlass, in: .rect(cornerRadius: DesignTokens.Radius.routeSheet))
        }
        .background(DesignTokens.Colors.sheetDim, in: .rect(cornerRadius: DesignTokens.Radius.routeSheet))
    }

    /// The outgoing content fades out first, then the incoming content fades in, so the two never overlap.
    private var contentTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Layout.contentFadeIn),
                    removal: .opacity.animation(Layout.contentFadeOut))
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
            overline(for: option.label)
            metrics(summary: summary)
            ScheduleTicker(result: option.result) { status in
                if let status {
                    ScheduleStatusBlock(status: status)
                } else {
                    arrivalLine(summary)
                }
            }
        }
    }

    private func arrivalLine(_ summary: RouteCardSummary) -> some View {
        Text("Arrive by \([summary.arrivalTime, summary.arrivalPeriod].filter { !$0.isEmpty }.joined(separator: " "))")
            .typeScale(.subtitle)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func legList(option: RouteOption, summary: RouteCardSummary) -> some View {
        if option.result.hasScheduledLeg {
            ScheduleTicker(result: option.result) { status in
                RouteChoiceLegList(legRows: summary.legRows, schedule: status)
            }
        } else {
            RouteChoiceLegList(legRows: summary.legRows)
        }
    }

    private func overline(for label: RouteOption.Label) -> some View {
        let (text, symbol) = overlineContent(label)
        return HStack(spacing: Layout.overlineSymbolSpacing) {
            Image(systemName: symbol)
            Text(text)
        }
        .typeScale(.subtitleEmphasis)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func overlineContent(_ label: RouteOption.Label) -> (String, String) {
        switch label {
        case .fastest:  (Strings.fastest, "bolt.fill")
        case .balanced: (Strings.balanced, "scalemass.fill")
        case .cheapest: (Strings.cheapest, "pesosign.circle.fill")
        }
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DesignTokens.Space.sm) {
                duration(summary)
                fareCapsule(summary)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                duration(summary)
                fareCapsule(summary)
            }
        }
    }

    private func duration(_ summary: RouteCardSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xs) {
            ForEach(summary.durationParts, id: \.self) { part in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xxs) {
                    Text(part.value)
                        .typeScale(.display)
                    Text(part.unit)
                        .typeScale(.instruction)
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func fareCapsule(_ summary: RouteCardSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.xxs) {
            Text("₱\(summary.fareText)")
                .typeScale(.subtitleEmphasis)
                .monospacedDigit()
            Text(Strings.fare)
                .typeScale(.subtitle)
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Space.m)
        .padding(.vertical, Layout.fareVerticalPadding)
        .frame(minHeight: Layout.fareMinHeight)
        .background(Color.jade.opacity(Layout.fareTintOpacity), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.fareText) pesos")
    }

    // MARK: Actions

    private func actionRow(option: RouteOption) -> some View {
        VStack(spacing: Layout.actionSpacing) {
            if canStartCommute {
                ScheduleTicker(result: option.result) { status in
                    useButton(option: option, status: status)
                }
                .frame(maxWidth: .infinity)
            } else {
                startHint
            }
            detailsButton
        }
    }

    private var detailsButton: some View {
        Button {
            withAnimation(DesignTokens.Motion.routeDetail(reduceMotion: reduceMotion)) {
                isDetailExpanded.toggle()
            }
        } label: {
            HStack(spacing: Layout.labelSpacing) {
                Image(systemName: "chevron.up")
                    .font(.body.weight(.semibold))
                    .rotationEffect(.degrees(isDetailExpanded && !reduceMotion ? 180 : 0))
                    .scaleEffect(y: isDetailExpanded && reduceMotion ? -1 : 1)
                    .accessibilityHidden(true)
                detailsLabel
            }
            .animation(labelMotion, value: isDetailExpanded)
            .foregroundStyle(DesignTokens.Colors.secondaryAction)
            .modifier(SheetActionSize())
            .background(DesignTokens.Colors.secondaryActionFill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDetailExpanded ? Strings.showSummary : Strings.showDetails)
    }

    /// One text whose glyphs morph into the new label. The full-width button keeps its size.
    private var detailsLabel: some View {
        Text(isDetailExpanded ? Strings.showSummary : Strings.showDetails)
            .typeScale(.sheetActionLabel)
            .multilineTextAlignment(.center)
            .contentTransition(reduceMotion ? .opacity : .interpolate)
            .accessibilityHidden(true)
    }

    private var labelMotion: Animation {
        reduceMotion ? Layout.labelMotionReduced : Layout.labelMotion
    }

    private func useButton(option: RouteOption, status: ScheduleStatus?) -> some View {
        let reason = status.flatMap { ScheduleCopy($0, uses24HourTime: use24HourTime).buttonReason }
        let isOff = reason != nil
        return Button {
            onUse(option)
        } label: {
            VStack(spacing: 0) {
                Text(Strings.useRoute)
                    .typeScale(.sheetActionLabel)
                if let reason {
                    Text(reason)
                        .typeScale(.subtitle)
                        .lineLimit(Layout.reasonLines)
                } else if status != nil, dynamicTypeSize.isAccessibilitySize {
                    Text(" ")
                        .typeScale(.subtitle)
                        .lineLimit(Layout.reasonLines, reservesSpace: true)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(DesignTokens.Colors.onAction)
            .modifier(SheetActionSize())
            .goraGlass(.regular.interactive(), tint: DesignTokens.Colors.action, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(isOff ? Layout.offOpacity : 1)
        .disabled(isOff)
        .accessibilityHint(reason ?? "")
        .animation(reduceMotion ? nil : Layout.readyFade, value: isOff)
    }

    private var startHint: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Image(systemName: "location.slash")
                .typeScale(.subtitle)
            Text("Go to the starting point to begin")
                .typeScale(.subtitle)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
    }
}

// MARK: - Summary cache

/// Holds the summary of the shown option. The sheet body runs on every map-panel frame, and
/// building a summary scans every raw step of every leg. It rebuilds only when its inputs change.
private final class SummaryCache {
    private struct Key: Equatable {
        let optionID: RouteOption.ID
        let legIDs: [UUID]
        let totalMinutes: Double
        let uses24HourTime: Bool
        let includesOtherModes: Bool
        let graphVersion: String?
    }

    private var entry: (key: Key, summary: RouteCardSummary)?

    func summary(for option: RouteOption, uses24HourTime: Bool, includesOtherModes: Bool,
                 graphVersion: String?, build: () -> RouteCardSummary) -> RouteCardSummary {
        let key = Key(optionID: option.id, legIDs: option.result.legs.map(\.id),
                      totalMinutes: option.result.totalTimeMinutes, uses24HourTime: uses24HourTime,
                      includesOtherModes: includesOtherModes, graphVersion: graphVersion)
        if let entry, entry.key == key { return entry.summary }
        let summary = build()
        entry = (key, summary)
        return summary
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
                .environment(RouteStore())
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

/// Size shared by the two sheet action buttons. The height scales with the same text style as the label.
private struct SheetActionSize: ViewModifier {
    private enum Layout {
        static let height: CGFloat = 53
        static let horizontalPadding: CGFloat = 20
    }

    @ScaledMetric(relativeTo: .body) private var height = Layout.height

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Layout.horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
