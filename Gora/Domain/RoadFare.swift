//
//  RoadFare.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 11/20/26.
//

import Foundation

/// The distance fare of one road leg, before the toll share.
nonisolated enum RoadFare {
    /// The leg's fare km is the fare km difference of its two end stops when both have one.
    /// Otherwise it is the measured distance of the leg.
    static func fareKm(boarding: Station, alighting: Station, measuredKm: Double) -> Double {
        guard let start = boarding.fareKm, let end = alighting.fareKm else { return measuredKm }
        return abs(end - start)
    }

    /// The base fare covers the line's free distance. Each km past it costs the per-km rate.
    /// The fare km rounds up to the line's step first.
    /// The amount then rounds to the nearest 25 centavos, as LTFRB fare guides do.
    static func amount(baseFare: Double, farePerKm: Double, baseKm: Double?, fareStepKm: Double?,
                       fareKm: Double) -> Double {
        let raw = baseFare + max(0, chargedKm(fareKm, stepKm: fareStepKm) - (baseKm ?? 0)) * farePerKm
        return (raw / Rounding.fareStepPesos).rounded(.toNearestOrAwayFromZero) * Rounding.fareStepPesos
    }

    /// Rounds up to the next multiple of the step. The tolerance keeps float noise, such as
    /// 4.0000001 km, from adding a step.
    private static func chargedKm(_ km: Double, stepKm: Double?) -> Double {
        guard let stepKm, stepKm > 0 else { return km }
        return max(0, ((km - Rounding.toleranceKm) / stepKm).rounded(.up) * stepKm)
    }

    private enum Rounding {
        static let toleranceKm = 0.01
        static let fareStepPesos = 0.25
    }
}
