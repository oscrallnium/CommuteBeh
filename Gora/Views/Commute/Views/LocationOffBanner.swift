//
//  LocationOffBanner.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/19/26.
//

import SwiftUI

/// The Liquid Glass banner that says Location is off and offers Turn On. Turn On opens the
/// shared alert through `RouteStore`. A nil `onDismiss` hides the Dismiss button.
struct LocationOffBanner: View {
    let subtitle: String
    let onDismiss: (() -> Void)?

    @Environment(RouteStore.self) private var routeStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Layout {
        static let minHeight: CGFloat = 56
        static let cornerRadius: CGFloat = 28
        static let buttonMinHeight: CGFloat = 44
        static let iconSize: CGFloat = 20
        static let contentSpacing = DesignTokens.Space.s
        static let buttonHorizontalPadding = DesignTokens.Space.ml
        static let subtitleMinScale: CGFloat = 0.8
        static let padding = EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 6)
    }

    private enum Strings {
        static let title = "Location is off"
        static let turnOn = "Turn On"
        static let dismiss = "Dismiss"
    }

    var body: some View {
        content
            .padding(Layout.padding)
            .frame(maxWidth: .infinity, minHeight: Layout.minHeight, alignment: .leading)
            .background {
                Color.clear.goraGlass(DesignTokens.Materials.cardGlass,
                                      in: .rect(cornerRadius: Layout.cornerRadius))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(Strings.title). \(subtitle)")
    }

    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Layout.contentSpacing) {
                message
                HStack(spacing: Layout.contentSpacing) {
                    turnOnButton
                    Spacer(minLength: 0)
                    dismissButton
                }
            }
        } else {
            HStack(spacing: Layout.contentSpacing) {
                message
                turnOnButton
                dismissButton
            }
        }
    }

    private var message: some View {
        HStack(spacing: Layout.contentSpacing) {
            Image(systemName: "location.slash")
                .font(.system(size: Layout.iconSize))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(Strings.title)
                    .typeScale(.subtitleEmphasis)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .typeScale(.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(Layout.subtitleMinScale)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private var turnOnButton: some View {
        Button {
            routeStore.isTurnOnLocationAlertPresented = true
        } label: {
            Text(Strings.turnOn)
                .typeScale(.subtitleEmphasis)
                .foregroundStyle(DesignTokens.Colors.onAction)
                .lineLimit(1)
                .padding(.horizontal, Layout.buttonHorizontalPadding)
                .frame(minHeight: Layout.buttonMinHeight)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(DesignTokens.Colors.action, in: .capsule)
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: Layout.iconSize * 0.7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.buttonMinHeight, height: Layout.buttonMinHeight)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.dismiss)
        }
    }
}

#if DEBUG
#Preview("Location off banner") {
    ZStack(alignment: .bottom) {
        Color(.systemGray4).ignoresSafeArea()
        VStack(spacing: DesignTokens.Space.s) {
            LocationOffBanner(subtitle: "The map can’t show where you are.", onDismiss: {})
            LocationOffBanner(subtitle: "Tap each step as you go.", onDismiss: nil)
        }
        .padding(DesignTokens.Space.l)
    }
    .environment(RouteStore())
}
#endif
