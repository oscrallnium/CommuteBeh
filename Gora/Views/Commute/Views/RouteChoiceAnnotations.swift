//
//  RouteChoiceAnnotations.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

// MARK: - Route Annotation Scale

enum RouteAnnotationScale {
    /// Smallest zoom scale for callouts and the destination pin, so they stay legible.
    static let floor = 0.6
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
