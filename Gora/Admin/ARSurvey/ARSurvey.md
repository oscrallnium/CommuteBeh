# AR Survey

The AR Survey screens record a world map and the signs in it. A survey lives in
`Application Support/ARSurveys/<id>/`.

## Survey folder

| File | Content |
|---|---|
| `metadata.json` | `ARSurveyMetadata`, snake_case keys, ISO 8601 dates |
| `worldmap.bin` | The zlib-compressed `ARWorldMap` archive |
| `image_<uuid>.png` | One file per sign image anchor |

`ARSurveyStore` reads and writes the folder. `save` writes the new image files with the other two
files. Load the world map and the images off the main actor.

## Sign placement

The user taps at the reticle, then names the sign in `ARSignDetailsSheet`. Each sign is an
`ARAnchor` named `node_<uuid>`.

## Sign images

A sign image is a photo of a permanent sign. The walk uses it to find the survey frame.
`ARSurveyImageAnchor` stores the name, the physical width in meters, the pose and the file name.

- `transform` holds 16 floats, column-major. It is the image pose in the survey world frame.
  The +Y axis is the image normal, as ARKit defines an image anchor.
- A `metadata.json` without `transform` or `file_name` still decodes. Both fields then default to
  empty.
- `ARSurveyStore.validate` reports an error when a listed image file is missing.

### Capture flow

1. "Add Sign Image" shows `ARSignFramingGuide`. `ARSignFraming.rect(in:)` defines the rectangle.
2. "Capture" calls `captureSignImage()` on the scene (`ARSurveyImageCapture.swift`).
3. The scene maps the rectangle to camera image coordinates with `ARFrame.displayTransform`. It
   crops with Core Image and rotates the crop upright. The saved file is upright.
4. The scene raycasts the centre and the left and right edge midpoints against vertical planes.
   It tries `.existingPlaneGeometry`, then `.estimatedPlane`. All three hits use one strategy.
5. The width is the distance between the two edge hits. The pose origin is the centre hit.
   The +Y axis is the plane normal that faces the camera. The +X axis runs from the left hit to
   the right hit.
6. If a raycast fails, the screen shows "Point at a flat sign on a wall" and saves nothing.
7. The view model builds an `ARReferenceImage` and calls `validate`. A rejected image shows its
   reason and saves nothing.
8. `ARSignImageNameSheet` asks for a name. The view model adds the image anchor to the metadata
   and holds the PNG data until the next save.

The HUD shows the number and the names of the image anchors.

## Files

| File | Job |
|---|---|
| `ARSurveyModels.swift` | Metadata types and JSON coding |
| `ARSurveyStore.swift` | Folder read, write, image I/O and validation |
| `ARSurveyViewModel.swift` | Survey state, sign placement, image capture, save |
| `ARSurveyView.swift` | The screen and its sheets |
| `ARSurveySceneView.swift` | The `ARView` host and the session delegate |
| `ARSurveyImageCapture.swift` | Crop, raycast and pose for a sign image |
| `ARSurveyHUD.swift` | Status panel, framing guide and capture bar |
| `ARSignImageNameSheet.swift` | Name entry for a sign image |
