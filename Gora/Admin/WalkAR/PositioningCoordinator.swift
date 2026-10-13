//
//  PositioningCoordinator.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/13/26.
//

import Foundation
import simd

/// The only place that chooses the tier. Callers send inputs with `send` and read `snapshots`.
/// The scene view sends one sample at 10 Hz. The actor publishes one snapshot per sample.
actor PositioningCoordinator {
    /// A fix moves the estimate by at most this much.
    nonisolated static let l4PullLimitMeters = 3.0
    /// The pull toward GPS fades out, because the alignment absorbs it.
    nonisolated static let pullDecaySeconds = 10.0
    nonisolated static let minPitchRadians = -50.0 * Double.pi / 180
    nonisolated static let untrustedConfidenceCap = 0.7

    let snapshots: AsyncStream<PositioningSnapshot>
    private let inbox: AsyncStream<PositioningInput>.Continuation
    private let inboxStream: AsyncStream<PositioningInput>
    private let sink: AsyncStream<PositioningSnapshot>.Continuation

    private let routeLength: Double
    private let gate = GPSConfidenceGate()
    private var machine = TierMachine()
    private var surveyState: SurveyState?
    private var unplacedSince: TimeInterval = 0
    private var startedAt: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var l2ImagePosition: SIMD3<Float>?
    private var l2Confidence = 0.0
    private var lastAcceptedFix: GPSFix?
    private var lastAcceptedFixTime: TimeInterval?
    private var pull = 0.0
    private var routeS = 0.0
    private var isSeeded = false
    private var isBatteryLow = false

    init(routeLength: Double) {
        self.routeLength = routeLength
        let output = AsyncStream.makeStream(of: PositioningSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        snapshots = output.stream
        sink = output.continuation
        let queue = AsyncStream.makeStream(of: PositioningInput.self)
        inboxStream = queue.stream
        inbox = queue.continuation
    }

    /// Queues an input. It keeps the call order.
    nonisolated func send(_ input: PositioningInput) {
        inbox.yield(input)
    }

    /// Ends the input queue, which ends `run` and `snapshots`.
    nonisolated func finish() {
        inbox.finish()
    }

    /// Handles inputs until `finish` runs. Call it once.
    func run() async {
        for await input in inboxStream { handle(input) }
        sink.finish()
    }

    private func handle(_ input: PositioningInput) {
        switch input {
        case .surveyReady(let time):
            surveyState = .waiting
            unplacedSince = time
        case .relocalized:
            surveyState = .relocalizedL1
            l2ImagePosition = nil
        case .placedByL2(_, let imagePosition):
            guard surveyState != .relocalizedL1 else { return }
            surveyState = .placedByL2
            l2ImagePosition = imagePosition
            l2Confidence = 1
        case .sample(let sample):
            process(sample)
        case .fix(let fix, let routeDistance, let now):
            accept(fix, routeDistance: routeDistance, now: now)
        }
    }

    // MARK: Fixes

    private func accept(_ fix: GPSFix, routeDistance: Double, now: TimeInterval) {
        guard gate.rejection(for: fix, previous: lastAcceptedFix, now: now) == nil else { return }
        lastAcceptedFix = fix
        lastAcceptedFixTime = now
        let limit = isSeeded ? Self.l4PullLimitMeters : .infinity
        pull += max(-limit, min(limit, routeDistance - routeS))
    }

    // MARK: Samples

    private func process(_ sample: PositioningSample) {
        let started = startedAt ?? sample.time
        startedAt = started
        advance(with: sample)
        let input = machineInput(for: sample)
        let machineTier = machine.update(input)
        let isStarting = sample.time - started < TierMachine.upshiftSettleSeconds
        var tier = isStarting ? GuidanceTier.t2Directional : machineTier
        var reason = isStarting ? TierReason.acquiring : self.reason(for: tier, input: input)
        if surveyState == .timedOut, !hardFixHolds, reason != .devicePower {
            tier = .t4Recovery
            reason = .noRecentHardFix
        }
        let estimate = PositionEstimate(s: routeS, heading: nil, confidence: input.routeConfidence,
                                        authoritativeRung: input.hasRecentGatedGPS ? .l4GPS : .l3Odometry,
                                        time: sample.time)
        sink.yield(PositioningSnapshot(estimate: estimate, tier: tier, reason: reason, surveyState: surveyState,
                                       showsSurveySigns: tier.showsSurveySigns(hardFixHolds: hardFixHolds)))
    }

    /// Updates the survey state and the estimate along the route.
    private func advance(with sample: PositioningSample) {
        let dt = lastSampleTime.map { max(0, sample.time - $0) } ?? 0
        lastSampleTime = sample.time
        decayL2(at: sample.time, cameraPosition: sample.cameraPosition)
        refreshSurveyState(at: sample.time)
        isSeeded = sample.alignment.isSeeded
        pull *= exp(-dt / Self.pullDecaySeconds)
        routeS = max(0, min(routeLength, sample.alignment.progress + pull))
        if sample.batteryFraction < TierMachine.criticalBatteryFraction { isBatteryLow = true }
    }

    /// L2 confidence falls with the distance from the detected image. At 0 the state returns to waiting.
    private func decayL2(at time: TimeInterval, cameraPosition: SIMD3<Float>) {
        guard surveyState == .placedByL2, let image = l2ImagePosition else { return }
        l2Confidence = SurveyFrameSolver.l2Confidence(distanceFromImage: Double(simd_distance(image, cameraPosition)))
        guard l2Confidence == 0 else { return }
        surveyState = .waiting
        unplacedSince = time
        l2ImagePosition = nil
    }

    private func refreshSurveyState(at time: TimeInterval) {
        guard let state = surveyState, state == .waiting || state == .timedOut else { return }
        surveyState = SurveyState.whileUnplaced(elapsed: time - unplacedSince)
    }

    private var hardFixHolds: Bool {
        guard let state = surveyState else { return false }
        return state == .relocalizedL1 || (state == .placedByL2 && l2Confidence > 0)
    }

    // MARK: Tier

    private func machineInput(for sample: PositioningSample) -> TierMachine.Input {
        let isFixRecent = lastAcceptedFixTime.map { sample.time - $0 <= GPSConfidenceGate.fixMaxAgeSeconds } ?? false
        return TierMachine.Input(
            routeConfidence: routeConfidence(sample.alignment),
            // The route aligns from GPS and the compass, not from the survey, so no hard-fix rule applies.
            metersSinceHardFix: nil,
            isTrackingNormal: sample.isTrackingNormal,
            hasRecentGatedGPS: isFixRecent,
            isCameraBelowMinPitch: sample.pitchRadians < Self.minPitchRadians,
            power: sample.power,
            isThermalSerious: sample.isThermalSerious,
            batteryFraction: sample.batteryFraction,
            time: sample.time)
    }

    /// An unseeded alignment gives the T2 floor, so the screen chevron guides from GPS and compass.
    /// A trusted heading gives at least the T1 floor. An untrusted heading stays between the T2
    /// floor and 0.7, which keeps it below T1.
    private func routeConfidence(_ alignment: PositioningAlignment) -> Double {
        guard alignment.isSeeded else { return TierMachine.t2FloorConfidence }
        if alignment.isHeadingTrusted { return max(alignment.yawConfidence, TierMachine.t1FloorConfidence) }
        return min(max(alignment.yawConfidence, TierMachine.t2FloorConfidence), Self.untrustedConfidenceCap)
    }

    private func reason(for tier: GuidanceTier, input: TierMachine.Input) -> TierReason {
        if tier >= .t3NonAR, isBatteryLow || input.isThermalSerious || input.power == .critical { return .devicePower }
        if tier == .t1Precise { return .aligned }
        if input.isCameraBelowMinPitch { return .cameraLowered }
        if !input.isTrackingNormal { return .trackingLimited }
        if let walked = input.metersSinceHardFix, walked > TierMachine.t1StaleMeters { return .noRecentHardFix }
        return .lowConfidence
    }
}
