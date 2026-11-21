//
//  CommuteManualStep.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/19/26.
//

import SwiftUI

/// The current step as the commute card shows it while Location is off. Every name is `Station.name`.
struct CommuteManualStep: Equatable {
    /// Zero-based leg index.
    let index: Int
    let count: Int
    let mode: TransportMode
    let color: Color
    let title: String
    let subtitle: String
    let buttonTitle: String

    var isLast: Bool { index == count - 1 }
    var position: String { "Step \(index + 1) of \(count)" }

    private enum Strings {
        static let arrived = "I’ve Arrived"
        static let toDestination = "Walk to your destination"
    }

    /// Returns nil when `index` is not a leg of `legs`.
    init?(legs: [RouteLeg], index: Int, lineName: (String) -> String, legColor: (RouteLeg) -> Color) {
        guard legs.indices.contains(index) else { return nil }
        let leg = legs[index]
        let isLast = index == legs.count - 1
        self.index = index
        count = legs.count
        mode = leg.mode
        color = legColor(leg)
        if CommuteLegRowModel.isWalkStep(leg) {
            title = isLast ? Strings.toDestination : "Walk to \(leg.toStation.name)"
            subtitle = "\(RouteCardSummary.distanceLabel(leg.distanceKm)) · \(CommuteLegRowModel.durationText(for: leg))"
            buttonTitle = isLast ? Strings.arrived : "I’m at \(leg.toStation.name)"
        } else {
            title = "Ride \(lineName(leg.line))"
            let stops = leg.stopCount
            let stopText = stops > 0 ? " · \(stops) \(stops == 1 ? "stop" : "stops")" : ""
            subtitle = "Get off at \(leg.toStation.name)\(stopText)"
            buttonTitle = isLast ? Strings.arrived : "I Got Off at \(leg.toStation.name)"
        }
    }
}

// MARK: - Step row

/// The current step in the collapsed card: the mode icon, the title and the subtitle.
struct CommuteManualStepRow: View {
    let step: CommuteManualStep
    @Environment(\.self) private var environment

    private enum Layout {
        static let iconSize: CGFloat = 32
        static let verticalPadding = DesignTokens.Space.m
    }

    var body: some View {
        HStack(spacing: DesignTokens.Space.m) {
            step.mode.iconImage
                .font(.subheadline)
                .foregroundStyle(step.color.iconInk(in: environment))
                .frame(width: Layout.iconSize, height: Layout.iconSize)
                .background(step.color, in: .circle)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text(step.title)
                    .typeScale(.rowTitleLargeCurrent)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(step.subtitle)
                    .typeScale(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentTransition(.opacity)
        .animation(DesignTokens.Motion.locationState, value: step)
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current step: \(step.title). \(step.subtitle)")
    }
}

// MARK: - Step button

/// The one primary button of the collapsed and expanded card while Location is off.
struct CommuteManualStepButton: View {
    let step: CommuteManualStep
    let onTap: () -> Void

    private enum Layout {
        static let minHeight: CGFloat = 50
    }

    var body: some View {
        Button(action: onTap) {
            Text(step.buttonTitle)
                .typeScale(.controlLabel)
                .foregroundStyle(DesignTokens.Colors.onAction)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Layout.minHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(DesignTokens.Colors.action, in: .capsule)
        .contentTransition(.opacity)
        .animation(DesignTokens.Motion.locationState, value: step)
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.bottom, DesignTokens.Space.ml)
    }
}
