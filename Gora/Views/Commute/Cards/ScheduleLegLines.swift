//
//  ScheduleLegLines.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/16/26.
//

import SwiftUI

// MARK: - Schedule Leg Lines

/// The schedule line under a timetable leg of the expanded route list: the departure and the
/// arrival, in semibold.
struct ScheduleLegLines: View {
    let status: ScheduleStatus
    @AppStorage(SettingsKey.use24HourTime) private var use24HourTime = false

    private enum Layout {
        static let symbolSpacing = DesignTokens.Space.xs
    }

    var body: some View {
        let copy = ScheduleCopy(status, uses24HourTime: use24HourTime)
        VStack(alignment: .leading, spacing: DesignTokens.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.symbolSpacing) {
                Image(systemName: copy.symbol)
                Text(copy.legHeadline)
            }
            .typeScale(.subtitleEmphasis)
        }
        .accessibilityElement(children: .combine)
    }
}
