# WalkAR

This folder holds Walk AR. It shows world-locked chevrons along a walking route. The
route comes from GPS and the compass. An optional saved AR survey adds signs.

## Files

| File | Job |
|---|---|
| WalkARScreen | Full-screen host. It keeps the screen on while it shows. |
| WalkARSceneView | `ARView` host and `ARSessionDelegate`. It owns the floor, the signs and the power response. |
| WalkARViewModel | Aligns the AR frame to the route. It publishes the HUD, the screen guide and the latest tier. |
| PositioningCoordinator | Actor. It is the only place that chooses the tier. |
| PositioningSnapshot | The `Sendable` values that go into and out of the coordinator. |
| WalkARGuidanceScene | Chevrons, lead arrow and callout under one root entity. |
| WalkARTurnCallout | The turn label and bars. |
| WalkARScreenChevron | Screen-space chevron. `WalkARScreenChevronLayer` reads the view model itself. |
| WalkARScreenGuide | Guide value, angle smoother and next-decision type. |
| WalkARScreenProjector | Screen direction to a world target. |
| WalkARPowerPolicy | Reads thermal state and Low Power Mode. It publishes one `WalkARPowerState`. |
| WalkARLocationService | GPS and compass feed. The heading filter is 3 degrees. |
| WalkARSurvey | Loads a saved survey: the world map, the sign image references and the sign poses. |
| WalkARHUD | Text overlay. |
| WalkARTestView, WalkRoutePickerModel | Admin route picker. It stops its location manager while AR shows. |

## Rates

| Work | Rate |
|---|---|
| Alignment, progress, lead arrow | Each frame |
| Screen guide and edge projection | 20 Hz (`guideInterval`) |
| HUD | 4 Hz, on change |
| Floor query and plane pruning | 10 Hz. Planes beyond 15 m are dropped. |
| Survey sign visibility | 1 Hz, and at once when the tier changes the permission. Signs show within 40 m of the camera. |
| Coordinator input and snapshot | 10 Hz. One sample in, one snapshot out. |

The guide angle stays continuous and is not wrapped. The chevron rotation uses a
linear animation of one guide interval.

## Power

`WalkARPowerState` has three values: `full`, `reduced`, `critical`.

- `reduced` is Low Power Mode or thermal `.serious`. The session starts with a 30 fps
  video format, and the scene disables every second chevron slot.
- `critical` is thermal `.critical`. The coordinator pauses the session and hides the scene.
  GPS and compass callbacks then drive the centre chevron.
- A state that returns below `critical` runs the session again and drops the alignment.

## Session events

An interruption hides the scene. When it ends, the coordinator clears the planes and the
floor, and the view model drops its alignment.

## Localization ladder logic

These files hold pure logic. They take plain values and import no ARKit, RealityKit, SwiftUI or
CoreLocation. A unit test can drive them without a device.

| File | Job |
|---|---|
| PositionEstimate | `PositionEstimate` (`s`, heading, confidence, rung, time) and `Rung`. |
| GuidanceTier | T1 to T4, with what each tier may show. |
| GPSConfidenceGate | Accepts a `GPSFix` or returns a `GPSRejection`. The caller computes the snap residual. |
| TierMachine | Holds the tier. A worse tier applies at once. A better tier applies after 1.5 s. |
| SurveyFrameSolver | Survey-to-session transform from one sign image, and the L2 confidence decay. |
| SurveyState | Waiting, relocalized by L1, placed by L2, or timed out after 15 s. |

`TierMachine` reads `WalkARPowerState.critical` and the `isThermalSerious` input as T3 triggers.
Low Power Mode alone does not change the tier. A battery below 10 percent holds T3 or worse for
the rest of the session.

The 25 m stale rule and the 60 m T4 rule apply only when `metersSinceHardFix` has a value. An
outdoor walk with no survey has no hard-fix rung, so it passes `nil`, and its route tier comes
from the alignment confidence alone.

## Positioning coordinator

`PositioningCoordinator` is an actor. It chooses the tier. No view, scene or HUD reads the
tracking state or the GPS accuracy to decide what to show. They read the tier and the survey state.

Data flow:

1. `WalkARSceneView.Coordinator` builds one `PositioningSample` every 0.1 s from the AR frame. It
   holds the camera position and pitch, the tracking state, the alignment values from the view
   model, the power state, the thermal flag and the battery level. An unknown battery level counts as full.
2. The view model sends each GPS fix as `.fix`, with its distance from the route. The scene view
   sends `.surveyReady` at start and `.relocalized` on the L1 event.
3. The actor handles the inputs in arrival order. It publishes one `PositioningSnapshot` for each sample.
4. The view model applies the snapshot. It observes `tier`, `tierReason` and `surveyState`. The
   estimate and the survey sign flag stay outside observation.

A power change also sends a sample, so the tier follows a paused session that has no frames.

### Estimate along the route

- `s` is the L3 progress from the alignment, plus a pull toward each accepted GPS fix.
- A fix passes `GPSConfidenceGate` first. It moves `s` by 3 m at most. An unseeded alignment takes the whole step.
- The pull fades with a time constant of 10 s, because the alignment absorbs it.
- `s` stays between 0 and the route length. This is the route snap.
- The authoritative rung is `l4GPS` while an accepted fix is under 5 s old. Otherwise it is `l3Odometry`.

### Route confidence

| Alignment | Confidence |
|---|---|
| Not seeded | 0.45 (T2 floor) |
| Seeded, heading trusted | The yaw confidence, at least 0.75 (T1 floor) |
| Seeded, heading not trusted | The yaw confidence, held between 0.45 and 0.7 |

A heading is trusted when the compass seed is within 25 degrees or the yaw estimate is confident.
The tracking state, the camera pitch, the power state and the hard-fix distance reach the tier
through `TierMachine`.

### Survey state and hard fix

- A survey that loads sends `.surveyReady`. The state is `waiting`.
- `.relocalized` sets `relocalizedL1`. L1 always wins over L2.
- `.placedByL2` sets `placedByL2`, unless L1 already happened. The hard fix holds.
- A `waiting` state becomes `timedOut` after 15 s. L1 or L2 replaces `timedOut`.
- When the survey state is `timedOut` and no hard fix holds, the tier is T4 with the reason
  `noRecentHardFix`. A power reason keeps its tier.
- The route tier always passes `metersSinceHardFix` as `nil`. The route aligns from GPS and the
  compass, so a survey hard fix does not change it.
- Survey signs follow `GuidanceTier.showsSurveySigns(hardFixHolds:)`. A hard fix holds after L1,
  and while the L2 confidence is above 0.

### L2 sign image placement

1. `WalkARSurvey` loads the sign images off the main actor with the world map. It skips an image
   anchor that has no file, no valid pose or an unreadable file. It builds one `ARReferenceImage`
   for each, named with the image anchor id. It also reads the sign poses from the world map anchors.
2. `attach` sets `detectionImages` and `maximumNumberOfTrackedImages = 1`. Tracking keeps the
   image anchor updating, so the placement refreshes while the image stays in view.
3. For a tracked `ARImageAnchor`, the scene view computes `T_session_survey` with
   `SurveyFrameSolver.sessionFromSurvey`. It does this at most once per second for each image.
4. Each sign within 30 m of the image, measured in the survey frame, stands on its own
   `AnchorEntity` at `T_session_survey * T_survey_sign`. A later detection moves the same entities.
5. The scene view sends `.placedByL2` with the image position in the session frame.
6. The coordinator sets the L2 confidence with `SurveyFrameSolver.l2Confidence`. The distance is
   the straight line from the camera to the image. At 0 the hard fix stops, and the state returns
   to `waiting` with a new 15 s timeout.
7. L1 removes the L2 entities and shows the signs at their live anchors. The scene view then
   ignores image anchors.

L2 signs use the same visibility rule as L1 signs: the tier permission and 40 m from the camera.

### What each tier shows

| Tier | Scene | Screen | HUD |
|---|---|---|---|
| T1 | World-locked route, lead arrow, callouts | Edge pointer | Instruction card |
| T2 | Hidden | Centre chevron and distance | Instruction card |
| T3 | Camera hidden | Centre chevron, from GPS and the compass | Instruction card and "You can lower your phone." |
| T4 | Hidden | None | Instruction card and the coaching card |

The HUD also shows the coaching card while the survey state is `timedOut`. For the first 1.5 s after
the first sample, the tier is T2 with the reason `acquiring`, so the screen does not flash T3.
A tier change fades the world root and the camera view over 0.4 s. It has no sound, haptic or banner.
Survey signs switch at once.

## Coaching card

`WalkARCoachingCard` shows in T4 and while the survey state is `timedOut`. `WalkARScreen` passes it
the survey metadata as a plain value. The title reads "Point your camera at the <sign name> sign."
for the first image anchor that has a file. Without such an anchor, it reads "Stand where the survey
was scanned and face the same way." A thumbnail loads off the main actor. The card also shows the
light condition and age ("Scanned at dusk, 18 hours ago"), and a row of the other signs.
