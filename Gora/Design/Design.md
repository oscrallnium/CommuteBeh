# Design

`DesignTokens.swift` holds the type, spacing, radius, color and motion tokens. Views use these
tokens and the color assets. Views do not use literal values.

## Color principle: one hue, one meaning

Each hue has exactly one meaning. The transport modes take five hues, the accent takes orange, and
status takes green and red. Interface chrome builds emphasis from neutrals, as Apple Maps does.
Do not use a mode hue, the accent or a status color for any other meaning.

## Color assets

### Brand and action

| Asset | Swift symbol | Light / dark | Role |
|---|---|---|---|
| Tangerine | `Color.tangerine` | #FF8A3D / #FF8A3D | Primary action fill, position puck, current leg. Text on it is always Licorice. |
| Ember | `Color.ember` | #A8480A / #FF8A3D | Accent text and glyphs, links. The `AccentColor` asset has the same values, so system controls use it. |
| Licorice | `Color.licorice` | #16110C / #16110C | Text and glyphs on a Tangerine fill |

### Transport modes

Mode hues mark route lines, mode icons and legs only. They never mark a button, a badge or a selection.

| Mode | Asset | Light / dark |
|---|---|---|
| Train | `Color.orchid` | #B5308F / #F27AD0 |
| Bus | `Color.cobalt` | #1F63D6 / #5B9DFF |
| Jeepney | `Color.amethyst` | #7247D8 / #B18CFF |
| Tricycle | `Color.chartreuse` | #5F7F0E / #B9DB4C |
| Walk | `Color.mist` | #4B5561 / #D5DCE3 |

The route choice leg list fills each ride leg's circle with its leg color. The glyph ink comes from the fill's luminance (`Color.contrastingInk(in:)`).

`TransportMode.color` maps each mode to its asset. A line color comes from the graph's `colorHex`
first, then from the mode color. Swift code never holds a per-line color.

### Status

| Asset | Swift symbol | Light / dark | Role |
|---|---|---|---|
| Jade | `Color.jade` | #1D9E5E / #34D07F | Schedule status, success, saved |
| Vermilion | `Color.vermilion` | #D93A2F / #FF7A6E | Destructive action, error, failure |

### Selection

| Asset | Swift symbol | Light / dark | Role |
|---|---|---|---|
| Lagoon | `Color.lagoon` | #0E7C86 / #4FD1DC | Selection inside a sheet form, and the elevator kind in the AR survey. Never on the map, where it reads as the green status or the bus blue. |

### Neutrals

| Asset | Swift symbol | Role |
|---|---|---|
| Onyx | `Color.onyx` | Text, glyphs and rings on opaque surfaces. Fill of a selected chip, badge or pin, with Canvas content. |
| Slate | `Color.slate` | Labels and subtitles on opaque surfaces |
| Faint | `Color.faint` | Completed legs, grabber, disabled content on opaque surfaces |
| Smoke | `Color.smoke` | Dividers, rings, connectors |
| Haze | `Color.haze` | Icon chip, leg chip, quiet badge and secondary button fill |
| Graphite | `Color.graphite` | Opaque floating surface |
| Canvas | `Color.canvas` | Route casing, node fill, content on an Onyx fill. Light value #FFFFFF, because routes draw on Apple Maps tiles. The design file's warm #F0EDE4 applies only to its custom map ground. |
| Charcoal Espresso | `Color.charcoal` | Unused. Do not add uses. |

## Emphasis without a hue

| Need | Use |
|---|---|
| Primary action | Tangerine fill, Licorice label |
| Secondary action | Haze fill, Onyx label |
| Control over the map | Liquid Glass, `.primary` and `.secondary` label |
| Selected state | Onyx fill, Canvas content. In a sheet form, Lagoon. |
| Badge, such as Fastest or Cheapest | Onyx or Haze fill with an SF Symbol. The symbol carries the meaning, not the color. |

Xcode does not generate a SwiftUI `Color` static for `Lagoon` or `Charcoal Espresso`.
`ColorAssets.swift` declares `Color.lagoon` and `Color.charcoal` by hand, from the asset name. If a later Xcode generates
`Color.lagoon`, the build reports a duplicate declaration: then delete the line in `ColorAssets.swift`.

## Light and dark mode

- Every chromatic asset except Tangerine and Licorice has a darker light value and a lighter dark
  value, so lines and icons keep at least 3:1 contrast on light tiles and on the dark canvas. A new
  asset follows the same rule.
- Never put white text on Tangerine. White on #FF8A3D is about 2.4:1.
- A fixed `.white` or `.black` is allowed only for a known contrast: a ring around a colored
  marker, a scrim over live camera video, or a shadow.

## Rules

- R1: The Tangerine fill marks the position, the current leg and the primary action only. Ember is
  the app tint for controls and links.
- R2: Green marks status only.
- R3: A mode hue marks its mode only.
- R4: Text and glyphs on Liquid Glass or a material use `.primary`, `.secondary` and `.tertiary`,
  not Onyx, Slate or Faint. Content on an opaque fill keeps its token.
- R6: No text is smaller than 12 pt. Use `.caption` as the smallest style.
- R7: Spacing comes from stack `spacing:` with a `Space` token, not from per-element padding.
- R8: Nothing inside a card has a shadow. Depth exists only where a surface floats over the map.

## Known exceptions

| Where | Value | Reason |
|---|---|---|
| `StationAccessPoint.directionTint` | Licorice, `Color(white: 0.38)`, `Color(white: 0.52)` | A fixed white symbol sits on the fill in both modes. Onyx turns white in dark mode. |
| `GoraLiveActivity/LiveActivityPalette.swift` | Hex values | The widget extension does not share the app's asset catalog. |
| AR survey sign panels | White text on the kind color | Low contrast on Tangerine and Jade. Open follow-up. |
