//
//  SettingsChoicePage.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/14/26.
//

import SwiftUI

/// A setting that has a fixed list of choices, stored by raw value.
protocol SettingsChoice: CaseIterable, Identifiable, Hashable, RawRepresentable where RawValue == String {
    var title: String { get }
}

extension SettingsChoice {
    var id: String { rawValue }
}

/// The routing engine does not read this choice yet. Named `RoutePriority` because the domain
/// layer already has `RoutePreference`, the A* tuning namespace.
enum RoutePriority: String, SettingsChoice {
    case fastest, fewestTransfers, cheapest, leastWalking

    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .fewestTransfers: "Fewest Transfers"
        case .cheapest: "Cheapest"
        case .leastWalking: "Least Walking"
        }
    }
}

/// Fare estimates do not use this choice yet.
enum FareDiscount: String, SettingsChoice {
    case none, student, seniorCitizen, pwd

    var title: String {
        switch self {
        case .none: "None"
        case .student: "Student"
        case .seniorCitizen: "Senior Citizen"
        case .pwd: "PWD"
        }
    }
}

/// A pushed page with an inline checkmark list of the choices.
struct SettingsChoicePage<Choice: SettingsChoice>: View {
    let title: String
    @Binding var selection: Choice

    var body: some View {
        List {
            Picker(title, selection: $selection) {
                ForEach(Array(Choice.allCases)) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
