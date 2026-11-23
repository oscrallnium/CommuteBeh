//
//  CommuteLiveActivity.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/3/26.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            CommuteLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(LiveActivityPalette.background)
                .activitySystemActionForegroundColor(LiveActivityPalette.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(state: context.state)
                }
                // The trailing region stays empty.
                DynamicIslandExpandedRegion(.trailing) {
                    Color.clear
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBody(attributes: context.attributes, state: context.state,
                                       isStale: context.isStale)
                }
            } compactLeading: {
                IslandCompactBar(progress: context.state.progress, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTime(state: context.state, isStale: context.isStale)
            } minimal: {
                IslandMinimalRing(progress: context.state.progress, isStale: context.isStale)
            }
        }
    }
}
