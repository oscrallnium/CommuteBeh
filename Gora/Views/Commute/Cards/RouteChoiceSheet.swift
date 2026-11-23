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
    /// True when the sheet shows only the summary block and the start action. `isDetailExpanded` keeps the state to return to.
    @Binding var isCompressed: Bool
    /// False until the user is within 500 m of the route origin. The sheet then shows a hint
    /// in place of the "Start Commute" button.
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
    @State private var rawProgress: CGFloat?
    @State private var listHeight: CGFloat = 0
    @State private var detailsHeight: CGFloat = 0

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
        static let startActionHeight: CGFloat = 50
    }

    private enum Strings {
        static let fastest = "Fastest"
        static let balanced = "Balanced"
        static let cheapest = "Cheapest"
        static let fare = "fare"
        static let useRoute = "Start Commute"
        static let showDetails = "Show Route Details"
        static let showSummary = "Show Route Summary"
        static let handle = "Route sheet handle"
        static let compress = "Compress Sheet"
        static let expand = "Expand Sheet"
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
        VStack(alignment: .leading, spacing: 0) {
            header(option: option, summary: summary)
            CompressibleSection(progress: progress, naturalHeight: $listHeight) {
                listSection(option: option, summary: summary)
            }
            startAction(option: option)
                .padding(.top, DesignTokens.Space.m)
            CompressibleSection(progress: progress, naturalHeight: $detailsHeight) {
                detailsButton
                    .padding(.top, Layout.actionSpacing)
            }
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
        .offset(y: RouteSheetCompressMath.overshoot(raw: rawProgress ?? restProgress, range: dragRange))
        .modifier(compressDrag(isActive: isCompressed))
    }

    // MARK: Compression

    private var restProgress: CGFloat { isCompressed ? 1 : 0 }

    /// 0 shows the previous state and 1 shows the compressed state.
    private var progress: CGFloat { RouteSheetCompressMath.clamped(rawProgress ?? restProgress) }

    private var dragRange: CGFloat { listHeight + detailsHeight }

    private func compressDrag(isActive: Bool) -> RouteSheetCompressDrag {
        RouteSheetCompressDrag(isCompressed: $isCompressed, rawProgress: $rawProgress,
                               range: dragRange, isActive: isActive)
    }

    private func setCompressed(_ value: Bool) {
        guard value != isCompressed else { return }
        withAnimation(DesignTokens.Motion.routeDetail(reduceMotion: reduceMotion)) {
            isCompressed = value
        }
    }

    /// The outgoing content fades out first, then the incoming content fades in, so the two never overlap.
    private var contentTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Layout.contentFadeIn),
                    removal: .opacity.animation(Layout.contentFadeOut))
    }

    // MARK: Header

    private func header(option: RouteOption, summary: RouteCardSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            grabber
            summaryBlock(option: option, summary: summary)
        }
        .contentShape(.rect)
        .modifier(compressDrag(isActive: !isCompressed))
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.indicator)
            .fill(Color.faint)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.handle)
            .accessibilityAction(named: Strings.compress) { setCompressed(true) }
            .accessibilityAction(named: Strings.expand) { setCompressed(false) }
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

    /// The schedule row and the ride list or leg list. Each child carries its own top padding.
    private func listSection(option: RouteOption, summary: RouteCardSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if option.result.hasScheduledLeg {
                ScheduleTicker(result: option.result) { status in
                    if let status {
                        ScheduleTripRow(status: status)
                            .padding(.top, DesignTokens.Space.m)
                    }
                }
            }
            listContent(option: option, summary: summary)
                .padding(.top, DesignTokens.Space.m)
        }
    }

    @ViewBuilder
    private func listContent(option: RouteOption, summary: RouteCardSummary) -> some View {
        if isDetailExpanded {
            legList(option: option, summary: summary)
                .transition(contentTransition)
        } else {
            RouteChoiceRideList(summary: summary, isDetailExpanded: $isDetailExpanded)
                .transition(contentTransition)
        }
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

    @ViewBuilder
    private func startAction(option: RouteOption) -> some View {
        if canStartCommute {
            ScheduleTicker(result: option.result) { status in
                useButton(option: option, status: status)
            }
            .frame(maxWidth: .infinity)
        } else {
            startHint
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
        .frame(height: Layout.startActionHeight)
    }
}
