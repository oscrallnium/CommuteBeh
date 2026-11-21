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
    var arrivalTime: String
    /// Empty in 24-hour time.
    var arrivalPeriod: String
    let rows: [CommuteLegRowModel]
    let currentLegIndex: Int
    /// Non-nil once the passenger reaches the destination.
    let arrivedAt: Date?
    /// Non-nil while Location is off. The card then shows steps and an estimated arrival.
    var manualStep: CommuteManualStep?

    var subtitle: String {
        if let manualStep { return manualStep.position }
        if isRerouting { return "Rerouting…" }
        return [remainingText, speedText].compactMap { $0 }.joined(separator: " · ")
    }

    /// The label under the arrival time.
    var arrivalLabel: String { manualStep == nil ? "arrive" : "estimated" }

    /// What VoiceOver reads for the header while Location is off.
    var manualHeaderLabel: String {
        let time = [arrivalTime, arrivalPeriod].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(destination). \(manualStep?.position ?? ""). Estimated arrival \(time)."
    }
}

/// The floating commute card. The header shows in both states. The leg list shows below it in
/// the expanded state. A vertical drag on the header moves the card height live between the two.
struct CommuteSheetCard: View {
    let model: CommuteSheetModel
    @Binding var cardState: CommuteCardState
    @Binding var showEndAlert: Bool
    let onEndCommute: () -> Void
    /// Makes step `index` current. An index past the last step means the rider arrived.
    let onSelectStep: (Int) -> Void

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

    private var isManual: Bool { model.manualStep != nil }
    /// Measured heights of the Location-off step row and step button. The card grows by them.
    @State private var stepRowHeight: CGFloat = 0
    @State private var stepButtonHeight: CGFloat = 0
    private var collapsedHeight: CGFloat {
        CommuteSheetHeight.collapsed + (isManual ? hairlineHeight + stepRowHeight + stepButtonHeight : 0)
    }
    private var expandedHeight: CGFloat { CommuteSheetHeight.expanded + (isManual ? stepButtonHeight : 0) }
    private var midpointHeight: CGFloat { (collapsedHeight + expandedHeight) / 2 }
    private func height(of state: CommuteCardState) -> CGFloat {
        state == .collapsed ? collapsedHeight : expandedHeight
    }

    private var cardHeight: CGFloat {
        guard model.arrivedAt == nil else { return CommuteSheetHeight.collapsed }
        return dragHeight ?? height(of: cardState)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.arrivedAt != nil {
                arrivedHeader
            } else {
                header
                details
                if let step = model.manualStep { stepButton(step) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight, alignment: .top)
        .animation(DesignTokens.Motion.locationState, value: isManual)
        .overlay(alignment: .top) { grabber }
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.commuteSheet))
        .goraGlass(DesignTokens.Materials.cardGlass, in: .rect(cornerRadius: DesignTokens.Radius.commuteSheet))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            let progress = (height - collapsedHeight) / (midpointHeight - collapsedHeight)
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
            Text(endAlertMessage)
        }
    }

    private var endAlertMessage: String {
        guard let step = model.manualStep else {
            return "Live guidance will stop and the remaining \(model.remainingText) will be discarded."
        }
        return "Guidance will stop. You are on step \(step.index + 1) of \(step.count)."
    }

    private var grabber: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: grabberSize.width, height: grabberSize.height)
            .padding(.top, grabberTop)
            .allowsHitTesting(false)
    }

    // MARK: Header

    /// With Location off, VoiceOver reads one label that names the step and the estimated arrival.
    @ViewBuilder
    private var header: some View {
        if isManual {
            headerContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.manualHeaderLabel)
                .accessibilityAddTraits(isExpanded ? [] : .isButton)
        } else {
            headerContent
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isExpanded ? [] : .isButton)
        }
    }

    private var headerContent: some View {
        HStack(spacing: DesignTokens.Space.m) {
            VStack(alignment: .leading, spacing: titleSpacing) {
                Text(model.destination)
                    .typeScale(.instruction)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.subtitle)
                    .typeScale(.bodyLarge).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(DesignTokens.Motion.locationState, value: model.manualStep)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(model.arrivalTime)
                        .typeScale(.etaLarge).monospacedDigit()
                        .tracking(-0.22)
                        .foregroundStyle(.primary)
                    if !model.arrivalPeriod.isEmpty {
                        Text(model.arrivalPeriod)
                            .typeScale(.rowTitle)
                            .foregroundStyle(.primary)
                    }
                }
                Text(model.arrivalLabel)
                    .typeScale(.body)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(DesignTokens.Motion.locationState, value: isManual)
            }
        }
        .padding(.top, DesignTokens.Space.xl)
        .padding(.horizontal, DesignTokens.Space.l)
        .padding(.bottom, DesignTokens.Space.ml)
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .simultaneousGesture(resizeDrag)
    }

    /// Always in the layout, so the card height reveals it during a drag. It takes only the
    /// height left under the header and clips the rest.
    private var details: some View {
        VStack(spacing: 0) {
            hairline
            if let step = model.manualStep {
                manualDetails(step)
            } else {
                CommuteLegList(rows: model.rows, currentLegIndex: model.currentLegIndex)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .opacity(isManual ? 1 : detailsOpacity)
        .allowsHitTesting(isManual || isExpanded)
        .accessibilityHidden(!isManual && !isExpanded)
    }

    /// The current step fades into the tappable leg list as the card grows.
    private func manualDetails(_ step: CommuteManualStep) -> some View {
        ZStack(alignment: .top) {
            CommuteLegList(rows: model.rows, currentLegIndex: model.currentLegIndex, onSelectStep: onSelectStep)
                .opacity(detailsOpacity)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            CommuteManualStepRow(step: step)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepRowHeight = $0 }
                .opacity(1 - detailsOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(isExpanded)
        }
    }

    private func stepButton(_ step: CommuteManualStep) -> some View {
        CommuteManualStepButton(step: step) { onSelectStep(step.index + 1) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepButtonHeight = $0 }
    }

    private var arrivedHeader: some View {
        HStack(spacing: DesignTokens.Space.m) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
                Text(model.destination)
                    .typeScale(.instruction)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Arrived")
                    .typeScale(.rowTitle)
                    .foregroundStyle(Color.jade)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onEndCommute) {
                Text("Done")
                    .typeScale(.controlLabel)
                    .foregroundStyle(DesignTokens.Colors.onAction)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Colors.action)
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
        // Global space: the header moves with the card height, so a local translation would
        // shrink as the finger moves and make the card stutter.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let height = height(of: cardState) - value.translation.height
                dragHeight = min(expandedHeight, max(collapsedHeight, height))
            }
            .onEnded { value in
                let live = dragHeight ?? height(of: cardState)
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
        return height >= midpointHeight ? .expanded : .collapsed
    }
}

#if DEBUG
extension CommuteSheetModel {
    static var preview: CommuteSheetModel {
        CommuteSheetModel(
            destination: RoutePreviewFixtures.destinationName, remainingText: "10.4 km",
            speedText: "32 km/h", isRerouting: false, arrivalTime: "6:55", arrivalPeriod: "PM",
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
                             showEndAlert: .constant(false), onEndCommute: {}, onSelectStep: { _ in })
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
