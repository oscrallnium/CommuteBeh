//
//  WalkARViewModel.swift
//  Gora
//
//  Created by Oscar Allen Brioso on 10/12/26.
//

import CoreLocation
import Observation
import simd

/// Tracking quality as the view model sees it. The AR layer maps `ARCamera.trackingState` to it.
enum WalkARTrackingQuality: Equatable {
    case normal
    case limited
    case unavailable

    var label: String {
        switch self {
        case .normal: "Good"
        case .limited: "Limited"
        case .unavailable: "Not available"
        }
    }
}

/// Text and numbers that the HUD shows.
struct WalkARHUDState: Equatable {
    var instruction = "Looking for your position"
    var metersLeft: Double = 0
    var yawConfidence: Double = 0
    var gpsAccuracy: Double?
    var tracking: WalkARTrackingQuality = .unavailable
    var warning: String?
}

/// Aligns the AR frame to the walk polyline and publishes what the HUD and the scene need.
/// The AR layer feeds it one call per frame. Its only ARKit value is the survey world map.
@Observable
final class WalkARViewModel {
    static let acceptedAccuracyMeters = 20.0
    static let maxSeedHeadingAccuracyDegrees = 25.0
    static let originSlewMetersPerSecond = 0.5
    static let yawSlewDegreesPerSecond = 6.0
    static let maxFrameStepSeconds = 0.25
    static let hudInterval: TimeInterval = 0.25
    static let arrivalMeters = 8.0
    static let guideInterval: TimeInterval = 0.05
    static let lowConfidenceWarning = "Walk a few steps so the arrows can line up"

    let path: PolylinePath
    let turns: [WalkTurn]
    let survey: WalkARSurvey?
    private(set) var hud = WalkARHUDState()
    private(set) var screenGuide: WalkARScreenGuide?
    private(set) var showsCenterGuide = false
    private(set) var tier = GuidanceTier.t2Directional
    private(set) var tierReason = TierReason.acquiring
    private(set) var surveyState: SurveyState?

    // Read by the AR layer every frame, so they stay outside observation.
    @ObservationIgnored private(set) var transform: GeoARTransform?
    @ObservationIgnored private(set) var progress: Double = 0
    @ObservationIgnored private(set) var showsSurveySigns = false
    @ObservationIgnored private(set) var estimate: PositionEstimate?
    @ObservationIgnored let positioning: PositioningCoordinator

    @ObservationIgnored private let location = WalkARLocationService()
    @ObservationIgnored private var targetTransform: GeoARTransform?
    @ObservationIgnored private var estimator: ARHeadingEstimator?
    @ObservationIgnored private var latestFix: CLLocation?
    @ObservationIgnored private var latestHeading: WalkARHeading?
    @ObservationIgnored private var seedHeadingAccuracy = Double.infinity
    @ObservationIgnored private var tracking: WalkARTrackingQuality = .unavailable
    @ObservationIgnored private var lastCamera: (position: SIMD3<Float>, forward: SIMD2<Float>?)?
    @ObservationIgnored private var lastFrameTime: TimeInterval?
    @ObservationIgnored private var lastHUDTime: TimeInterval = 0
    @ObservationIgnored private var arPathLength = 0.0
    @ObservationIgnored private var samples: [PoseFixSample] = []
    @ObservationIgnored private var lastPathPosition: SIMD3<Float>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var edgeSmoother = WalkARAngleSmoother()
    @ObservationIgnored private var centerSmoother = WalkARAngleSmoother()
    @ObservationIgnored private var lastGuideTime: TimeInterval = 0
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?

    private struct PoseFixSample {
        let ar: SIMD3<Float>
        let geo: Coordinates
        let time: TimeInterval
        let pathLength: Double
    }

    init(polyline: [Coordinates], surveyID: UUID? = nil) {
        survey = surveyID.map { WalkARSurvey(id: $0) }
        let route = PolylinePath(polyline)
        path = route
        turns = WalkTurnExtractor.turns(in: polyline)
        positioning = PositioningCoordinator(routeLength: route.length)
        location.onFix = { [weak self] in
            self?.receive(fix: $0)
            self?.updateGuideWithoutFrames()
        }
        location.onHeading = { [weak self] in
            self?.latestHeading = $0
            self?.updateGuideWithoutFrames()
        }
        location.onDenied = { [weak self] in self?.hud.warning = "Location access is off. Turn it on in Settings." }
    }

    func start() {
        guard !started else { return }
        started = true
        location.start()
        let positioning = positioning
        Task { await positioning.run() }
        let snapshots = positioning.snapshots
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots { self?.apply(snapshot) }
        }
    }

    func stop() {
        started = false
        location.stop()
        positioning.finish()
        snapshotTask?.cancel()
    }

    /// While paused no frames arrive, so the GPS and compass callbacks drive the centre chevron.
    /// Resuming drops the alignment, because the paused session lost its pose.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused { resetAlignmentAfterRelocalization() }
    }

    private func updateGuideWithoutFrames() {
        guard isPaused else { return }
        updateScreenGuide(edgeAngle: nil, time: ProcessInfo.processInfo.systemUptime)
    }

    func loadSurvey() async {
        await survey?.load()
    }

    /// Drops the origin, the yaw, and the last fix. The next frames seed them again from the
    /// compass and the next accepted fix, because relocalization moves the session into the map frame.
    func resetAlignmentAfterRelocalization() {
        transform = nil
        targetTransform = nil
        estimator = nil
        latestFix = nil
        samples = []
        seedHeadingAccuracy = .infinity
        arPathLength = 0
        lastPathPosition = nil
        progress = 0
    }

    /// The alignment values that the positioning coordinator reads.
    var alignment: PositioningAlignment {
        PositioningAlignment(progress: progress, yawConfidence: estimator?.confidence ?? 0, isSeeded: transform != nil,
                             isHeadingTrusted: seedHeadingAccuracy <= Self.maxSeedHeadingAccuracyDegrees
                                 || estimator?.isConfident == true)
    }

    private func apply(_ snapshot: PositioningSnapshot) {
        estimate = snapshot.estimate
        showsSurveySigns = snapshot.showsSurveySigns
        if tier != snapshot.tier { tier = snapshot.tier }
        if tierReason != snapshot.reason { tierReason = snapshot.reason }
        if surveyState != snapshot.surveyState { surveyState = snapshot.surveyState }
    }

    // MARK: Frames

    /// One call per AR frame. `forward` is the camera forward vector projected to horizontal.
    func handleFrame(cameraPosition: SIMD3<Float>, forward: SIMD2<Float>?, tracking: WalkARTrackingQuality, time: TimeInterval) {
        self.tracking = tracking
        lastCamera = (cameraPosition, forward)
        let dt = min(Self.maxFrameStepSeconds, max(0, time - (lastFrameTime ?? time)))
        accumulatePathLength(to: cameraPosition, tracking: tracking)
        lastFrameTime = time
        if targetTransform == nil { seedIfPossible() }
        slew(by: dt)
        updateProgress(cameraPosition: cameraPosition)
        publishHUD(time: time)
    }

    private func accumulatePathLength(to position: SIMD3<Float>, tracking: WalkARTrackingQuality) {
        defer { lastPathPosition = position }
        guard tracking == .normal, let last = lastPathPosition else { return }
        arPathLength += Double(simd_length(SIMD2(position.x - last.x, position.z - last.z)))
    }

    private func slew(by dt: Double) {
        guard let current = transform, let target = targetTransform else { return }
        transform = current.slewed(toward: target,
                                   maxMeters: Self.originSlewMetersPerSecond * dt,
                                   maxRadians: Self.yawSlewDegreesPerSecond * .pi / 180 * dt)
    }

    private func updateProgress(cameraPosition: SIMD3<Float>) {
        guard let transform else { return }
        guard let projection = path.project(transform.coordinates(ofAR: cameraPosition)) else { return }
        progress = projection.distanceAlong
    }

    // MARK: Fixes

    private func receive(fix: CLLocation) {
        latestFix = fix
        report(fix)
        guard fix.horizontalAccuracy <= Self.acceptedAccuracyMeters, tracking == .normal,
              let camera = lastCamera,
              let snapped = path.project(Coordinates(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude))
        else { return }
        let time = lastFrameTime ?? 0
        guard var estimator, targetTransform != nil else {
            seedIfPossible()
            return
        }
        samples.append(PoseFixSample(ar: camera.position, geo: snapped.coordinate, time: time, pathLength: arPathLength))
        if let pair = displacementPair(endingAt: samples[samples.count - 1]) {
            estimator.add(pair)
            self.estimator = estimator
            samples = [samples[samples.count - 1]]
        } else {
            samples.removeAll { time - $0.time > ARHeadingEstimator.maxElapsedSeconds }
        }
        let yaw = estimator.yaw
        let origin = GeoARTransform.origin(placing: snapped.coordinate, atAR: camera.position, yaw: yaw)
        targetTransform = GeoARTransform(origin: origin, yaw: yaw)
    }

    /// Sends the fix to the positioning coordinator with its distance from the route.
    private func report(_ fix: CLLocation) {
        let coordinate = Coordinates(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude)
        guard let snapped = path.project(coordinate) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let gpsFix = GPSFix(coordinate: coordinate, accuracy: fix.horizontalAccuracy,
                            timestamp: now - max(0, -fix.timestamp.timeIntervalSinceNow),
                            snapResidualMeters: snapped.distanceFromLine)
        positioning.send(.fix(gpsFix, routeDistance: snapped.distanceAlong, now: now))
    }

    private func displacementPair(endingAt end: PoseFixSample) -> ARDisplacementPair? {
        for start in samples.dropLast() {
            let pair = ARDisplacementPair(arStart: start.ar, arEnd: end.ar, geoStart: start.geo, geoEnd: end.geo,
                                          arPathLength: end.pathLength - start.pathLength, elapsed: end.time - start.time)
            if ARHeadingEstimator.yawSample(from: pair) != nil { return pair }
        }
        return nil
    }

    // MARK: Seed

    /// Seeds the yaw from the compass and the origin from the snapped fix.
    private func seedIfPossible() {
        guard tracking == .normal,
              let camera = lastCamera, let forward = camera.forward,
              let fix = latestFix, fix.horizontalAccuracy <= Self.acceptedAccuracyMeters,
              let heading = latestHeading, heading.trueDegrees >= 0, heading.accuracyDegrees >= 0,
              let snapped = path.project(Coordinates(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude))
        else { return }
        let yaw = GeoARTransform.yaw(trueHeadingDegrees: heading.trueDegrees, cameraForward: forward)
        let origin = GeoARTransform.origin(placing: snapped.coordinate, atAR: camera.position, yaw: yaw)
        let seeded = GeoARTransform(origin: origin, yaw: yaw)
        transform = seeded
        targetTransform = seeded
        estimator = ARHeadingEstimator(seedYaw: yaw)
        seedHeadingAccuracy = heading.accuracyDegrees
        arPathLength = 0
        samples = [PoseFixSample(ar: camera.position, geo: snapped.coordinate, time: lastFrameTime ?? 0, pathLength: 0)]
    }

    // MARK: HUD

    private func publishHUD(time: TimeInterval) {
        guard time - lastHUDTime >= Self.hudInterval else { return }
        lastHUDTime = time
        let confidence = estimator?.confidence ?? 0
        let isSeedUsable = seedHeadingAccuracy <= Self.maxSeedHeadingAccuracyDegrees
        var next = hud
        next.metersLeft = max(0, path.length - progress)
        next.yawConfidence = confidence
        next.gpsAccuracy = latestFix?.horizontalAccuracy
        next.tracking = tracking
        next.instruction = instruction(metersLeft: next.metersLeft)
        next.warning = warning(confidence: confidence, isSeedUsable: isSeedUsable)
        if next != hud { hud = next }
    }

    private func warning(confidence: Double, isSeedUsable: Bool) -> String? {
        if hud.warning?.hasPrefix("Location access") == true { return hud.warning }
        if transform == nil { return nil }
        if !isSeedUsable && estimator?.isConfident != true { return "Compass is not accurate. " + Self.lowConfidenceWarning }
        return confidence < ARHeadingEstimator.confidenceFloor ? Self.lowConfidenceWarning : nil
    }

    private func instruction(metersLeft: Double) -> String {
        guard transform != nil else { return "Looking for your position" }
        if metersLeft <= Self.arrivalMeters { return "You are near the destination" }
        guard let turn = turns.first(where: { $0.distanceAlong > progress }) else {
            return "Continue straight"
        }
        return Self.turnText(distance: turn.distanceAlong - progress, turn: turn)
    }

    /// "turn left", "bear right", "make a U-turn".
    static func actionPhrase(for turn: WalkTurn) -> String {
        let side = turn.side == .left ? "left" : "right"
        switch turn.kind {
        case .slight: return "bear \(side)"
        case .sharp: return "turn sharp \(side)"
        case .uTurn: return "make a U-turn"
        default: return "turn \(side)"
        }
    }

    /// "In 40 m, turn left". Distances round to 5 m.
    static func turnText(distance: Double, turn: WalkTurn) -> String {
        let action = actionPhrase(for: turn)
        let rounded = Int((distance / 5).rounded()) * 5
        return rounded < 5 ? "Ahead, \(action)" : "In \(rounded) m, \(action)"
    }

    // MARK: Screen guide

    /// The next decision and its distance, while the world-locked guidance shows.
    func edgeTarget() -> (decision: WalkARDecision, distance: Double)? {
        guard tier.showsWorldLockedRoute, transform != nil,
              let decision = WalkARDecision.next(after: progress, turns: turns, path: path) else { return nil }
        let distance = decision.distanceAlong - progress
        return isArriving(decision, distance: distance) ? nil : (decision, distance)
    }

    /// One call per AR frame. `edgeAngle` is the raw screen direction to the next decision.
    /// It runs only when a guide tick is due. T1 shows the edge chevron. T2 and T3 show the centre chevron.
    func updateScreenGuide(edgeAngle: @autoclosure () -> Double?, time: TimeInterval) {
        guard time - lastGuideTime >= Self.guideInterval else { return }
        let dt = min(Self.maxFrameStepSeconds, time - lastGuideTime)
        lastGuideTime = time
        let next: WalkARScreenGuide?
        switch tier {
        case .t1Precise:
            centerSmoother.reset()
            next = edgeGuide(angle: edgeAngle(), dt: dt)
        case .t2Directional, .t3NonAR:
            edgeSmoother.reset()
            next = centerGuide(dt: dt)
        case .t4Recovery:
            edgeSmoother.reset()
            centerSmoother.reset()
            next = nil
        }
        if next != screenGuide { screenGuide = next }
        let isCenter = next?.placement == .center
        if isCenter != showsCenterGuide { showsCenterGuide = isCenter }
    }

    private func edgeGuide(angle: Double?, dt: Double) -> WalkARScreenGuide? {
        guard let angle, let target = edgeTarget() else {
            edgeSmoother.reset()
            return nil
        }
        return WalkARScreenGuide(placement: .edge, angle: edgeSmoother.add(angle, dt: dt),
                                 title: WalkARDecision.roundedText(target.distance))
    }

    /// Points along the route at the snapped fix, relative to the compass heading.
    private func centerGuide(dt: Double) -> WalkARScreenGuide? {
        guard let fix = latestFix, fix.horizontalAccuracy <= Self.acceptedAccuracyMeters,
              let heading = latestHeading, heading.trueDegrees >= 0,
              let snapped = path.project(Coordinates(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude)),
              let sample = path.sample(at: snapped.distanceAlong),
              let decision = WalkARDecision.next(after: snapped.distanceAlong, turns: turns, path: path)
        else {
            centerSmoother.reset()
            return nil
        }
        let distance = decision.distanceAlong - snapped.distanceAlong
        guard !isArriving(decision, distance: distance) else {
            centerSmoother.reset()
            return nil
        }
        let routeBearing = GeoARTransform.bearing(ofENU: sample.direction)
        let relative = GeoARTransform.normalized(routeBearing - heading.trueDegrees * .pi / 180)
        return WalkARScreenGuide(placement: .center, angle: centerSmoother.add(relative, dt: dt),
                                 title: decision.directionalText(distance: distance))
    }

    private func isArriving(_ decision: WalkARDecision, distance: Double) -> Bool {
        decision.turn == nil && distance <= Self.arrivalMeters
    }
}
