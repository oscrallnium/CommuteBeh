//
//  RouteChoiceLineRows.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/13/26.
//

import SwiftUI

// MARK: - Route Choice Line Rows

/// The lines a passenger can ride on one open leg: name, fare, and payment icons.
/// Lines of the leg's own mode come first, then one section for each other mode.
struct RouteChoiceLineRows: View {
    let lines: [RouteCardSummary.LineOption]
    let sections: [RouteCardSummary.ModeSection]
    @Environment(RouteStore.self) private var routeStore

    private enum Layout {
        static let radius: CGFloat = 12
        static let padding = DesignTokens.Space.m
        static let rowSpacing = DesignTokens.Space.s
        static let nameLines = 2
    }

    private enum Strings {
        static let payWith = "Pay with"
        static let separator = " · "
        static let plus = "+"
        static let minus = "\u{2212}"
        static let min = "min"
        static let minute = "minute"
        static let minutes = "minutes"
        static let slower = "slower"
        static let faster = "faster"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            lineList(lines)
            ForEach(sections) { section in
                Divider()
                sectionHeader(section)
                lineList(section.lines)
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.haze, in: RoundedRectangle(cornerRadius: Layout.radius, style: .continuous))
    }

    private func lineList(_ lines: [RouteCardSummary.LineOption]) -> some View {
        ForEach(lines) { line in
            lineRow(line)
            if line.id != lines.last?.id { Divider() }
        }
    }

    private func sectionHeader(_ section: RouteCardSummary.ModeSection) -> some View {
        HStack(spacing: DesignTokens.Space.xs) {
            section.mode.iconImage
                .foregroundStyle(section.mode.color)
            Text(section.title)
                .typeScale(.subtitleEmphasis)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func lineRow(_ line: RouteCardSummary.LineOption) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            HStack(spacing: DesignTokens.Space.xs) {
                Text(line.name)
                    .typeScale(.subtitleEmphasis)
                    .lineLimit(Layout.nameLines)
                Spacer(minLength: DesignTokens.Space.s)
                if let detail = detailText(line) {
                    Text(detail)
                        .typeScale(.subtitle)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            paymentIcons(line.payments)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText(line))
    }

    /// "₱13 · +3 min": the fare, then the minute difference when it is not zero.
    private func detailText(_ line: RouteCardSummary.LineOption) -> String? {
        var parts: [String] = []
        if let fare = line.fareText { parts.append(fare) }
        if let delta = line.minutesDelta, delta != 0 {
            parts.append("\(delta > 0 ? Strings.plus : Strings.minus)\(abs(delta)) \(Strings.min)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: Strings.separator)
    }

    private func paymentIcons(_ payments: [String]) -> some View {
        HStack(spacing: DesignTokens.Space.xs) {
            ForEach(payments, id: \.self) {
                PaymentMethodIcon(paymentID: $0)
            }
        }
        .foregroundStyle(.primary)
    }

    private func spokenText(_ line: RouteCardSummary.LineOption) -> String {
        var parts = [line.name]
        if line.minutesDelta != nil { parts.insert(line.mode.displayName, at: 0) }
        if let fare = line.fareText { parts.append(fare) }
        if let delta = line.minutesDelta, delta != 0 {
            parts.append("\(abs(delta)) \(abs(delta) == 1 ? Strings.minute : Strings.minutes) \(delta > 0 ? Strings.slower : Strings.faster)")
        }
        if !line.payments.isEmpty {
            let names = line.payments.map { routeStore.paymentConfig($0)?.displayName ?? $0 }
            parts.append("\(Strings.payWith) \(names.formatted(.list(type: .and)))")
        }
        return parts.joined(separator: ", ")
    }
}
