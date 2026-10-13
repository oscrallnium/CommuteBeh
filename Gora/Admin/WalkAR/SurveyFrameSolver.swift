//
//  SurveyFrameSolver.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import simd

/// Frame math for the survey signs. All transforms are column-major, as in ARKit.
nonisolated struct SurveyFrameSolver {
    static let l2RadiusMeters = 30.0

    /// The survey frame in the session frame, from one detected sign image.
    static func sessionFromSurvey(imageInSession: simd_float4x4, imageInSurvey: simd_float4x4) -> simd_float4x4 {
        imageInSession * imageInSurvey.inverse
    }

    /// A survey-frame transform in the session frame.
    static func inSession(_ transform: simd_float4x4, sessionFromSurvey: simd_float4x4) -> simd_float4x4 {
        sessionFromSurvey * transform
    }

    /// 1 at the detected image, falling linearly to 0 at `l2RadiusMeters`.
    static func l2Confidence(distanceFromImage: Double) -> Double {
        max(0, min(1, 1 - distanceFromImage / l2RadiusMeters))
    }
}
