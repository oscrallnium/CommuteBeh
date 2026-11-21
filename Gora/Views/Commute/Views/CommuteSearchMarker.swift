//
//  CommuteSearchMarker.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/8/26.
//

import SwiftUI

/// Keys for the frames that the card rows and the route pill report. The panel moves each
/// marker and text from the card frame to the pill frame with the same key.
enum SearchGeometryID {
    static let originDot = "origin-dot"
    static let originText = "origin-text"
    static let destinationDot = "dest-dot"
    static let destinationText = "dest-text"
}

extension View {
    /// Stores this view's frame in `space` under `id`.
    func reportsFrame(
        _ id: String,
        in space: String,
        to frames: Binding<[String: CGRect]>
    ) -> some View {
        onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(space))
        } action: {
            frames.wrappedValue[id] = $0
        }
    }

    /// Shows or hides the view at once. An enclosing animation does not fade it.
    func snapsOpacity(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).animation(nil, value: visible)
    }
}

/// The origin or destination dot. The card rows, the route pill, and the panel's moving layer
/// draw it.
struct SearchMarker: View {
    enum Kind { case origin, destination }

    let kind: Kind

    var body: some View {
        Circle()
            .fill(center)
            .overlay(Circle().strokeBorder(ring, lineWidth: Layout.ringWidth))
            .frame(width: size, height: size)
    }

    /// The origin is 1 pt larger than the destination, because its ring is close to the card
    /// color and the marker otherwise looks smaller.
    private var size: CGFloat {
        switch kind {
        case .origin: Layout.originSize
        case .destination: Layout.destinationSize
        }
    }

    /// Origin: a Canvas ring. Destination: an Onyx ring, black and white in light mode and the reverse in dark mode.
    private var ring: Color {
        switch kind {
        case .origin: Color.canvas
        case .destination: Color.onyx
        }
    }

    private var center: Color {
        switch kind {
        case .origin: Color.tangerine
        case .destination: Color.canvas
        }
    }
}

private enum Layout {
    /// Keep sizes and `ringWidth` whole points; a fractional ring draws thicker on one side.
    static let originSize: CGFloat = 11
    static let destinationSize: CGFloat = 10
    static let ringWidth: CGFloat = 2
}
