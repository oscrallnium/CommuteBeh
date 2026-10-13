//
//  CommuteSheetCard.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import SwiftUI

/// The display values of the commute card. `CommuteModeView` builds one from the live
/// engine, and the previews build one from fixtures.
struct CommuteSheetModel {
    let destination: String
    let remainingText: String
    /// Nil while the speed is unknown or negative.
    let speedText: String?
    let isRerouting: Bool
    let arrivalTime: String
    let rows: [CommuteLegRowModel]
    let currentLegIndex: Int
    /// Non-nil once the passenger reaches the destination.
    let arrivedAt: Date?

    var subtitle: String {
        if isRerouting { return "Rerouting…" }
        return [remainingText, speedText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The floating commute card. The header shows in both states. The leg list shows below it in
/// the expanded state. A vertical drag on the header moves the card height live between the two.
struct CommuteSheetCard: View {
    let model: CommuteSheetModel
    @Binding var cardState: CommuteCardState
    @Binding var showEndAlert: Bool
    let onEndCommute: () -> Void

    private var isExpanded: Bool { cardState == .expanded }
    /// Opacity of the leg list. It follows the live card height, so the list shows during a drag.
    @State private var detailsOpacity: CGFloat = 0
    /// The card height while a drag runs. Nil outside a drag.
    @State private var dragHeight: CGFloat?

    private let titleSpacing: CGFloat = 2
    private let hairlineHeight: CGFloat = 0.5
    private let grabberSize = CGSize(width: 36, height: 5)
    private let grabberTop: CGFloat = 6
    /// Drag distance or release velocity above which the card follows the drag direction.
    private let flickThreshold: CGFloat = 24

    private var cardHeight: CGFloat {
        guard model.arrivedAt == nil else { return CommuteSheetHeight.collapsed }
        return dragHeight ?? cardState.height
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.arrivedAt != nil {
                arrivedHeader
            } else {
                header
                details
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight, alignment: .top)
        .overlay(alignment: .top) { grabber }
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.commuteSheet))
        .glassEffect(.clear, in: .rect(cornerRadius: DesignTokens.Radius.commuteSheet))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            let progress = (height - CommuteSheetHeight.collapsed)
                / (CommuteSheetHeight.midpoint - CommuteSheetHeight.collapsed)
            detailsOpacity = min(1, max(0, progress))
        }
        .onChange(of: model.arrivedAt) { _, arrivedAt in
            guard arrivedAt != nil else { return }
            withAnimation(DesignTokens.Motion.cardEnter) { cardState = .collapsed }
        }
        .alert("End Commute?", isPresented: $showEndAlert) {
            Button("Cancel", role: .cancel) {}
            Button("End Commute", role: .destructive, action: onEndCommute)
        } message: {
            Text("Live guidance will stop and the remaining \(model.remainingText) will be discarded.")
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: grabberSize.width, height: grabberSize.height)
            .padding(.top, grabberTop)
            .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.Space.m) {
            VStack(alignment: .leading, spacing: titleSpacing) {
                Text(model.destination)
                    .font(DesignTokens.TypeScale.instructionCompact)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.subtitle)
                    .font(DesignTokens.TypeScale.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(model.arrivalTime)
                    .font(DesignTokens.TypeScale.eta.monospacedDigit())
                    .tracking(-0.22)
                    .foregroundStyle(.primary)
                Text("arrive")
                    .font(DesignTokens.TypeScale.subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, DesignTokens.Space.xl)
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.bottom, DesignTokens.Space.ml)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .simultaneousGesture(resizeDrag)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isExpanded ? [] : .isButton)
    }

    /// Always in the layout, so the card height reveals it during a drag. It takes only the
    /// height left under the header and clips the rest.
    private var details: some View {
        VStack(spacing: 0) {
            hairline
            CommuteLegList(rows: model.rows, currentLegIndex: model.currentLegIndex)
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .opacity(detailsOpacity)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
    }

    private var arrivedHeader: some View {
        HStack(spacing: DesignTokens.Space.m) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text(model.destination)
                    .font(DesignTokens.TypeScale.instructionCompact)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Arrived")
                    .font(DesignTokens.TypeScale.subtitleEmphasis)
                    .foregroundStyle(Color.jade)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onEndCommute) {
                Text("Done")
                    .font(DesignTokens.TypeScale.controlLabel)
                    .foregroundStyle(Color.licorice)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tangerine)
        }
        .padding(.top, DesignTokens.Space.xl)
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.bottom, DesignTokens.Space.ml)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.smoke)
            .frame(height: hairlineHeight)
            .padding(.horizontal, DesignTokens.Space.l)
    }

    // MARK: Interaction

    private func expand() {
        guard !isExpanded else { return }
        withAnimation(DesignTokens.Motion.cardEnter) { cardState = .expanded }
    }

    /// Moves the card height with the finger, clamped between the two states. On release the
    /// card snaps to the nearer state, or follows the drag direction past `flickThreshold`.
    private var resizeDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let height = cardState.height - value.translation.height
                dragHeight = min(CommuteSheetHeight.expanded, max(CommuteSheetHeight.collapsed, height))
            }
            .onEnded { value in
                let live = dragHeight ?? cardState.height
                let target = snapTarget(height: live, translation: value.translation.height,
                                        velocity: value.velocity.height)
                withAnimation(DesignTokens.Motion.cardEnter) {
                    cardState = target
                    dragHeight = nil
                }
            }
    }

    private func snapTarget(height: CGFloat, translation: CGFloat, velocity: CGFloat) -> CommuteCardState {
        if abs(translation) > flickThreshold { return translation < 0 ? .expanded : .collapsed }
        if abs(velocity) > flickThreshold { return velocity < 0 ? .expanded : .collapsed }
        return height >= CommuteSheetHeight.midpoint ? .expanded : .collapsed
    }
}

#if DEBUG
extension CommuteSheetModel {
    static var preview: CommuteSheetModel {
        CommuteSheetModel(
            destination: RoutePreviewFixtures.destinationName, remainingText: "10.4 km",
            speedText: "32 km/h", isRerouting: false, arrivalTime: "6:55",
            rows: RoutePreviewFixtures.legRows, currentLegIndex: 1, arrivedAt: nil)
    }
}

/// Shows the card floating at the bottom of a grey stand-in for the map.
private struct CommuteSheetPreview: View {
    let state: CommuteCardState

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4)
            CommuteSheetCard(model: .preview, cardState: .constant(state),
                             showEndAlert: .constant(false), onEndCommute: {})
                .padding(.horizontal, DesignTokens.Space.l)
                .padding(.bottom, DesignTokens.Space.l)
        }
        .ignoresSafeArea()
    }
}

//#Preview("Collapsed · dark") {
//    CommuteSheetPreview(state: .collapsed).preferredColorScheme(.dark)
//}

#Preview("Collapsed · light") {
    CommuteSheetPreview(state: .collapsed).preferredColorScheme(.light)
}

//#Preview("Expanded · dark") {
//    CommuteSheetPreview(state: .expanded).preferredColorScheme(.dark)
//}

#Preview("Expanded · light") {
    CommuteSheetPreview(state: .expanded).preferredColorScheme(.light)
}
#endif
