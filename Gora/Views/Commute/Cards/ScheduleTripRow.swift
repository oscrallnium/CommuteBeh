//
//  ScheduleTripRow.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import SwiftUI

// MARK: - Schedule Trip Row

/// One row of the times the vehicle passes the boarding stop today. A trip the rider cannot
/// catch is secondary, and the next catchable trip sits in an outlined capsule with the word "Next".
/// After the last trip of today, a divider and the next service day follow. The row scrolls sideways.
struct ScheduleTripRow: View {
    let status: ScheduleStatus
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false
    @ScaledMetric(relativeTo: .subheadline) private var dividerHeight = Layout.dividerHeight

    private enum Layout {
        static let radius: CGFloat = 12
        static let padding = DesignTokens.Space.m
        static let itemSpacing = DesignTokens.Space.sm
        static let dividerHeight: CGFloat = 16
        static let dividerWidth: CGFloat = 1
        static let capsuleHorizontal: CGFloat = 10
        static let capsuleVertical = DesignTokens.Space.xxs
        static let capsuleBorder: CGFloat = 1.5
    }

    private enum Strings {
        static let today = "Today"
        static let noTrips = "No trips"
        static let next = "Next"
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.itemSpacing) {
                Text(Strings.today)
                    .typeScale(.subtitleEmphasis)
                    .foregroundStyle(.secondary)
                if status.todayTrips.isEmpty {
                    Text(Strings.noTrips)
                        .typeScale(.subtitle)
                        .foregroundStyle(.secondary)
                }
                ForEach(status.todayTrips) { trip in
                    tripLabel(trip.time, role: trip.role)
                }
                if let nextTrip = status.nextTrip {
                    nextDay(nextTrip)
                }
            }
            .lineLimit(1)
            .padding(Layout.padding)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haze, in: RoundedRectangle(cornerRadius: Layout.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScheduleCopy(status, uses24HourTime: use24HourTime).tripsSpoken)
    }

    @ViewBuilder
    private func tripLabel(_ time: Date, role: ScheduleStatus.TripRole) -> some View {
        let text = ScheduleFormat.time(time, uses24HourTime: use24HourTime)
        switch role {
        case .left, .tooSoon:
            Text(text).typeScale(.subtitle).monospacedDigit().foregroundStyle(.secondary)
        case .next:
            nextCapsule(text)
        case .later:
            Text(text).typeScale(.subtitle).monospacedDigit().foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func nextDay(_ date: Date) -> some View {
        Rectangle()
            .fill(.tertiary)
            .frame(width: Layout.dividerWidth, height: dividerHeight)
        Text(ScheduleFormat.day(date))
            .typeScale(.subtitleEmphasis)
            .foregroundStyle(.secondary)
        nextCapsule(ScheduleFormat.time(date, uses24HourTime: use24HourTime))
    }

    private func nextCapsule(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Text(Strings.next)
            Text(text).monospacedDigit()
        }
        .typeScale(.subtitleEmphasis)
        .foregroundStyle(.primary)
        .padding(.horizontal, Layout.capsuleHorizontal)
        .padding(.vertical, Layout.capsuleVertical)
        .overlay { Capsule().strokeBorder(.primary, lineWidth: Layout.capsuleBorder) }
    }
}
