//
//  PaymentFactRow.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/13/26.
//

import SwiftUI

// MARK: - Payment Fact Row

/// The payment line under the ride list, on one line that scrolls horizontally when it does not
/// fit. Methods that every line accepts show in the primary color. Others show dimmed.
struct PaymentFactRow: View {
    let full: [String]
    let partial: [String]
    @Environment(RouteStore.self) private var routeStore
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = RouteChoiceColumns.iconSize

    private enum Layout {
        static let spacing = DesignTokens.Space.xs
        static let fadeLength: CGFloat = 24
    }

    private enum Strings {
        static let separator = "·"
        static let payWith = "Pay with"
        static let onSomeLines = "on some lines only"
        static let leadingSymbol = "wallet.bifold"
    }

    var body: some View {
        HStack(alignment: .top, spacing: RouteChoiceColumns.iconSpacing) {
            Image(systemName: Strings.leadingSymbol)
                .typeScale(.subtitle)
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
            methods.layoutPriority(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }

    private var methods: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing) {
                ForEach(full, id: \.self) { PaymentMethodIcon(paymentID: $0).foregroundStyle(.primary) }
                if !partial.isEmpty {
                    if !full.isEmpty {
                        Text(Strings.separator).typeScale(.subtitle).foregroundStyle(.secondary)
                    }
                    ForEach(partial, id: \.self) { PaymentMethodIcon(paymentID: $0).foregroundStyle(.secondary) }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollEdgeFade(.trailing, length: Layout.fadeLength)
    }

    private var spokenText: String {
        let fullNames = full.map(name).formatted(.list(type: .and))
        let partialNames = partial.map(name).formatted(.list(type: .or))
        var parts: [String] = []
        if !full.isEmpty { parts.append("\(Strings.payWith) \(fullNames)") }
        if !partial.isEmpty { parts.append("\(partialNames) \(Strings.onSomeLines)") }
        return parts.joined(separator: ". ")
    }

    private func name(_ id: String) -> String {
        routeStore.paymentConfig(id)?.displayName ?? id
    }
}
