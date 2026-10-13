//
//  CommuteLiveActivityPreviews.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import ActivityKit
import SwiftUI
import WidgetKit

private enum PreviewData {
    static let attributes = CommuteActivityAttributes(
        segments: [
            .init(isWalk: true, weight: 4),
            .init(isWalk: false, weight: 18),
            .init(isWalk: true, weight: 5),
            .init(isWalk: false, weight: 12),
            .init(isWalk: true, weight: 3)
        ],
        boundaryLabels: [
            .init(position: 0, text: "Origin"),
            .init(position: 0.55, text: "Transfer stop"),
            .init(position: 1, text: "Destination")
        ],
        destinationName: "Destination")

    static func state(_ phase: CommuteActivityAttributes.Phase, progress: Double) -> CommuteState {
        CommuteState(
            phase: phase, progress: progress, eta: .now.addingTimeInterval(22 * 60),
            lastFixAt: .now.addingTimeInterval(-20),
            actionText: phase == .arrived ? "Arrived at Destination" : "Ride Line A to Stop B",
            legLabel: phase == .waiting ? "Transfer" : "Line A", stopsLeft: 7,
            nextLineName: "Line B", legIndex: 1)
    }

    static let live = state(.live, progress: 0.4)
    static let waiting = state(.waiting, progress: 0.55)
    static let arrived = state(.arrived, progress: 1)
}

private func lockCard(_ state: CommuteState, stale: Bool = false) -> some View {
    CommuteLockScreenView(attributes: PreviewData.attributes, state: state, isStale: stale)
        .background(LiveActivityPalette.background)
        .frame(width: 361)
}

#Preview("Lock live, light") { lockCard(PreviewData.live).preferredColorScheme(.light) }
#Preview("Lock live, dark") { lockCard(PreviewData.live).preferredColorScheme(.dark) }
#Preview("Lock waiting, light") { lockCard(PreviewData.waiting).preferredColorScheme(.light) }
#Preview("Lock waiting, dark") { lockCard(PreviewData.waiting).preferredColorScheme(.dark) }
#Preview("Lock stale, light") { lockCard(PreviewData.live, stale: true).preferredColorScheme(.light) }
#Preview("Lock stale, dark") { lockCard(PreviewData.live, stale: true).preferredColorScheme(.dark) }
#Preview("Lock arrived, light") { lockCard(PreviewData.arrived).preferredColorScheme(.light) }
#Preview("Lock arrived, dark") { lockCard(PreviewData.arrived).preferredColorScheme(.dark) }

private func islandExpanded(_ state: CommuteState, stale: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack {
            IslandExpandedLeading(state: state)
            Spacer()
            if state.phase != .arrived {
                CommuteETATimer(eta: state.eta, isStale: stale)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        IslandExpandedBody(attributes: PreviewData.attributes, state: state, isStale: stale)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .frame(width: 371)
    .background(.black, in: RoundedRectangle(cornerRadius: 44))
}

#Preview("Island expanded live") { islandExpanded(PreviewData.live) }
#Preview("Island expanded waiting") { islandExpanded(PreviewData.waiting) }
#Preview("Island expanded stale") { islandExpanded(PreviewData.live, stale: true) }
#Preview("Island expanded arrived") { islandExpanded(PreviewData.arrived) }

#Preview("Island compact", as: .dynamicIsland(.compact), using: PreviewData.attributes) {
    CommuteLiveActivity()
} contentStates: {
    PreviewData.live
    PreviewData.arrived
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: PreviewData.attributes) {
    CommuteLiveActivity()
} contentStates: {
    PreviewData.live
    PreviewData.arrived
}
