//
//  FareText.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import Foundation

/// Formats a fare for display.
nonisolated enum FareText {
    /// Whole pesos show no decimals ("176"). A fare with a fraction shows two ("176.25").
    static func amount(_ fare: Double) -> String {
        let cents = (fare * 100).rounded()
        return cents.truncatingRemainder(dividingBy: 100) == 0
            ? String(Int(cents / 100))
            : String(format: "%.2f", cents / 100)
    }

    /// The amount with the peso sign, for example "₱176.25".
    static func pesos(_ fare: Double) -> String { "₱" + amount(fare) }
}
