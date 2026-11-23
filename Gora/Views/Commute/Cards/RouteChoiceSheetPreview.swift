//
//  RouteChoiceSheetPreview.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/24/26.
//

import SwiftUI

#if DEBUG
private func previewStation(_ id: String, _ name: String, line: String, type: String) -> Station {
    Station(
        id: id, name: name, shortName: name, line: line, type: type,
        coordinates: Coordinates(lat: 14.5763, lng: 121.0194),
        isTerminal: false, isInterchange: false, interchangesWith: nil, amenities: [],
        operatingHours: .init(open: "05:30", close: "23:00"), accessPoints: nil, sequence: nil, boarding: nil
    )
}

private func previewLeg(
    _ from: Station, _ to: Station, mode: TransportMode, line: String,
    minutes: Double, fare: Double, instruction: String
) -> RouteLeg {
    RouteLeg(
        fromStation: from, toStation: to, mode: mode, line: line, direction: nil,
        stops: [from, to], effectiveTravelMinutes: minutes, fare: fare, distanceKm: 3,
        polylineCoordinates: [], estimatedArrival: Date().addingTimeInterval(minutes * 60),
        instruction: instruction, rawSteps: []
    )
}

private func previewOptions() -> [RouteOption] {
    let dela = previewStation("BUS_DELA_ROSA", "Dela Rosa", line: "EDSA_BUS", type: "bus")
    let gil = previewStation("LRT1_GIL", "Gil Puyat", line: "LRT-1", type: "train")
    let buendia = previewStation("LRT1_BUENDIA", "LRT Buendia", line: "LRT-1", type: "train")
    let legs = [
        previewLeg(dela, dela, mode: .walk, line: "ACCESS_WALK", minutes: 8, fare: 0,
                   instruction: "Walk to Dela Rosa"),
        previewLeg(dela, gil, mode: .bus, line: "EDSA_BUS", minutes: 18, fare: 22,
                   instruction: "Ride the bus northbound"),
        previewLeg(gil, buendia, mode: .train, line: "LRT-1", minutes: 12, fare: 26,
                   instruction: "LRT-1 southbound"),
    ]
    let result = RouteResult(legs: legs, totalTimeMinutes: 38, totalFare: 48,
                             totalDistanceKm: 9, transfers: 1, modes: [.bus, .train])
    return [RouteOption(result: result, label: .fastest)]
}

private struct RouteChoiceSheetPreview: View {
    @State private var selected: RouteOption.ID?
    @State var expanded: Bool
    @State var compressed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            RouteChoiceSheet(options: previewOptions(), selectedID: $selected,
                             isDetailExpanded: $expanded, isCompressed: $compressed,
                             canStartCommute: true,
                             onUse: { _ in }, legColor: { $0.mode.color })
                .environment(RouteStore())
                .padding(.horizontal, DesignTokens.Space.sm)
        }
    }
}

#Preview("Route Choice Sheet · light") {
    RouteChoiceSheetPreview(expanded: true).preferredColorScheme(.light)
}

#Preview("Route Choice Sheet · dark") {
    RouteChoiceSheetPreview(expanded: true).preferredColorScheme(.dark)
}

#Preview("Route Choice Sheet · collapsed") {
    RouteChoiceSheetPreview(expanded: false)
}

#Preview("Route Choice Sheet · compressed") {
    RouteChoiceSheetPreview(expanded: false, compressed: true)
}
#endif
