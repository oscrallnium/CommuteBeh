//
//  RouteChoiceAnnotations.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Route Annotation Scale

enum RouteAnnotationScale {
    /// Smallest zoom scale for bubbles and the destination pin, so they stay legible.
    static let floor = 0.6
}

// MARK: - Route Time Bubble

/// Travel-time capsule on a route. Tapping it selects the route.
struct RouteTimeBubble: View {
    let text: String
    let accessibilityText: String
    let isSelected: Bool
    let isShown: Bool
    let zoomScale: Double
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(DesignTokens.TypeScale.controlLabel)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.canvas : Color.onyx)
                .padding(.horizontal, DesignTokens.Space.l)
                .frame(height: 38)
                .background(isSelected ? Color.onyx : Color.graphite, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.smoke, lineWidth: 1))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isShown ? (isSelected ? 1.08 : 1) : 0.6)
        .opacity(isShown ? (isSelected ? 1 : 0.72) : 0)
        .scaleEffect(max(zoomScale, RouteAnnotationScale.floor))
        .animation(.snappy(duration: 0.25), value: isSelected)
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: isShown)
        .animation(.snappy(duration: 0.25), value: zoomScale)
        .allowsHitTesting(isShown)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(text)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Route Stop Marker

/// Destination or transfer marker. Tapping it selects the route it belongs to.
struct RouteStopMarker: View {
    let marker: RouteChoiceFrame.Marker
    let isSelected: Bool
    let zoomScale: Double
    let onTap: () -> Void

    private var isDestination: Bool { marker.kind == .destination }

    /// The destination pin shrinks with zoom, anchored at its tip. Other markers keep their size.
    private var scale: Double { isDestination ? max(zoomScale, RouteAnnotationScale.floor) : 1 }

    var body: some View {
        Button(action: onTap) {
            symbol
                .frame(minWidth: 44, minHeight: 44, alignment: isDestination ? .bottom : .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale, anchor: isDestination ? .bottom : .center)
        .opacity(isSelected ? 1 : 0.5)
        .animation(.snappy(duration: 0.25), value: isSelected)
        .animation(.snappy(duration: 0.25), value: scale)
        .accessibilityLabel("\(kindName), \(marker.name)")
        .accessibilityHint("Selects this route")
    }

    @ViewBuilder
    private var symbol: some View {
        switch marker.kind {
        case .destination:
            DestinationPin()
        case .transfer:
            TransferNode()
        }
    }

    private var kindName: String {
        switch marker.kind {
        case .destination: "Destination"
        case .transfer: "Transfer"
        }
    }
}

// MARK: - Destination Pin

/// The SF Symbol `mappin` in the ink color. It stays resizable, because font sizing adds
/// empty space under the needle. The view's bottom edge is the needle tip, so the tip sits on
/// the annotation coordinate when the annotation anchors at `.bottom`.
struct DestinationPin: View {
    var body: some View {
        Image(systemName: "mappin")
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .frame(height: 34)
            .foregroundStyle(Color.onyx)
    }
}

// MARK: - Preview

#if DEBUG
private struct RouteAnnotationPreview: View {
    var body: some View {
        ZStack {
            Color(.systemGray4)
            VStack(spacing: DesignTokens.Space.l) {
                HStack {
                    RouteTimeBubble(text: "38", accessibilityText: "Route", isSelected: true,
                                    isShown: true, zoomScale: 1, onTap: {})
                    RouteTimeBubble(text: "45", accessibilityText: "Route", isSelected: false,
                                    isShown: true, zoomScale: 1, onTap: {})
                }
                HStack {
                    TransferNode()
                    DestinationPin()
                }
            }
        }
    }
}

#Preview("Route Annotations · light") {
    RouteAnnotationPreview().preferredColorScheme(.light)
}

#Preview("Route Annotations · dark") {
    RouteAnnotationPreview().preferredColorScheme(.dark)
}
#endif
