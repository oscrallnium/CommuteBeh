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
| Tangerine | `Color.tangerine` | #FF8A3D / #FF8A3D | Position puck, origin marker, current leg. Not a button fill. |
| Ember | `Color.ember` | #A8480A / #FF8A3D | Accent text and glyphs, links. The `AccentColor` asset has the same values, so system controls use it. |
| Licorice | `Color.licorice` | #16110C / #16110C | Dark glyph ink that `iconInk(in:)` picks on a leg color. Not button text. |

### Transport modes

Mode hues mark route lines, mode icons and legs only. They never mark a button, a badge or a selection.

| Mode | Asset | Light / dark |
|---|---|---|
| Train | `Color.orchid` | #B5308F / #F27AD0 |
| Bus | `Color.plum` | #9B30B5 / #D98CF0 |
| Jeepney | `Color.amethyst` | #7247D8 / #B18CFF |
| Tricycle | `Color.chartreuse` | #5F7F0E / #B9DB4C |
| Walk | `Color.cocoa` | #7A5230 / #C79A6B |

Each mode hue has a contrast ratio of at least 3:1 against its glyph ink and at least 3:1 against the map, so the icon and the route line stay readable. Check a new mode hue against both rules.

The route choice leg list fills each ride leg's circle with its leg color. The glyph is white when white has at least 3:1 contrast on the fill (WCAG 1.4.11), else licorice (`Color.iconInk(in:)`). Text on a fill uses `Color.contrastingInk(in:)`, which picks the ink with the higher ratio.

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

### Payment icons

`PaymentMethodIcon` finds the assets in `Assets.xcassets/Payment` by the name `payment.<id>`, where `<id>` is the payment ID from the graph. Swift does not name a payment ID.

| Asset kind | Name | Result |
|---|---|---|
| Image set | `payment.<id>` | A brand image fills the badge. |
| Symbol set | `payment.<id>` | A custom symbol draws at symbol size in the center of the badge. |
| Color set | `payment.<id>.tint` | The color of the symbol. Without it, the symbol uses the color of the caller. |
| Color set | `payment.<id>.background` | The fill of the badge. Without it, the badge uses Haze. |

| Color | Light / dark | Role |
|---|---|---|
| `payment.cash.background` | #7A3FC6 in both modes | Cash badge fill. The violet of the 100-peso bill. |
| `payment.cash.tint` | #FFFFFF in both modes | Cash symbol. 6.3:1 on the violet fill. |
| `payment.card.background` | System blue | Card badge fill. |
| `payment.card.tint` | #FFFFFF in both modes | Card symbol. About 4:1 on the blue fill. |
| `payment.<id>.background` for gcash, maribank | #FFFFFF in both modes | Badge fill. |
| `payment.maya.background` | #000000 in both modes | Badge fill. |
| `payment.beep_card.background` | #1F2758 in both modes | Badge fill. |

Each tint has at least 3:1 contrast against its badge fill in both modes. A badge fill does not change with the mode, so a tint must not change either, unless it passes on that fill.

### Neutrals

| Asset | Swift symbol | Role |
|---|---|---|
| Onyx | `Color.onyx` | Text, glyphs and rings on opaque surfaces. Fill of a selected chip, badge or pin, with Canvas content. |
| Slate | `Color.slate` | Labels and subtitles on opaque surfaces |
| Faint | `Color.faint` | Completed legs, grabber, disabled content on opaque surfaces |
| Smoke | `Color.smoke` | Dividers, rings, connectors |
| Haze | `Color.haze` | Icon chip, leg chip, quiet badge and secondary button fill |
| Graphite | `Color.graphite` | Opaque floating surface |
| Vellum | `Color.vellum` | Fill of a `goraGlass` surface when Liquid Glass is off. #FFFFFF / #2A2F36. The dark value is lighter than the dark map, so the panel separates from it. |
| Powder | `Color.powder` | Fill of the Add Place chip when Liquid Glass is off. #C7D8F5, the same color as Cobalt at 25% on white. It has no dark value. |
| Canvas | `Color.canvas` | Node fill, dark-mode route casing, content on an Onyx fill. Light value #FFFFFF, because routes draw on Apple Maps tiles. The design file's warm #F0EDE4 applies only to its custom map ground. |
| CalloutSelected | `Color.calloutSelected` | Fill of the selected route-time callout. #FFFFFF / #1D3C41. |
| SelectionRing | `Color.selectionRing` | Inside ring of the selected route-time callout. #079EA3 in both modes. |
| CalloutSelectedLabel | `Color.calloutSelectedLabel` | Label under the time in the selected route-time callout. #525A64 / #9AA4B0. |
| Charcoal Espresso | `Color.charcoal` | Unused. Do not add uses. |

## Emphasis without a hue

| Need | Use |
|---|---|
| Primary action | `Color.cobalt` fill (`DesignTokens.Colors.action`), white label (`DesignTokens.Colors.onAction`). White on Cobalt is 5.5:1 in light mode and 2.7:1 in dark mode. The dark value fails the 4.5:1 text rule (see Known exceptions). |
| Secondary action | Haze fill (`DesignTokens.Colors.secondaryActionFill`) with a Cobalt label and symbol (`DesignTokens.Colors.secondaryAction`, the same blue as the primary action). Full width under the primary action in a sheet, 8 pt below it. On the map, the Haze fill sits on the chip glass. Measured in dark mode: 4.84:1 in the sheet, 3.76:1 on the solid fallback, 1.99:1 on dark glass. Light mode: 4.9:1 in the sheet, 4.5:1 on light glass. |
| Control over the map | Liquid Glass, `.primary` and `.secondary` label |
| Selected state | Onyx fill, Canvas content. In a sheet form, Lagoon. |
| Badge, such as Fastest or Cheapest | Onyx or Haze fill with an SF Symbol. The symbol carries the meaning, not the color. |

Xcode generates a SwiftUI `Color` static for each color asset, including `Color.lagoon`. Do not
declare an asset color by hand: the build then reports a duplicate declaration. A new asset that
is added outside Xcode gets its symbol on the next build that rescans the asset catalog.

## Light and dark mode

- Every chromatic asset except Tangerine and Licorice has a darker light value and a lighter dark
  value, so lines and icons keep at least 3:1 contrast on light tiles and on the dark canvas. A new
  asset follows the same rule.
- Never put white text on Tangerine. White on #FF8A3D is about 2.4:1.
- A fixed `.white` or `.black` is allowed only for a known contrast: a ring around a colored
  marker, a scrim over live camera video, or a shadow.

## Typography

The app text uses SF Pro, the system font. `DesignTokens.TypeScale` is the type scale: 16 cases,
each with a point `size`, a `weight`, and a `relativeTo` text style. Apply a case with
`.typeScale(.rowTitle)`, from `TypeScaleModifier.swift`.

- Change a size only in the `size` switch of `TypeScale`. The value is the size at the default
  Dynamic Type setting.
- `TypeScaleModifier` uses `@ScaledMetric`, so each size scales with Dynamic Type along the curve of
  its `relativeTo` style. `.system(size:)` alone does not scale, so do not use it for text that
  must scale.
- Use `.typeScale(_:)`, not `.font(_:)`, for a scale style. Chain `.monospacedDigit()` or
  `.tracking(_:)` after it.
- A font on an SF Symbol `Image` stays a system text style, such as `.font(.body.weight(.semibold))`,
  because the symbol takes its size and weight from it.

## Rules

- R1: The Tangerine fill marks the position and the current leg only. Primary buttons use Cobalt. Ember is
  the app tint for controls and links.
- R2: Green marks status only.
- R3: A mode hue marks its mode only.
- R4: Text and glyphs on Liquid Glass or a material use `.primary`, `.secondary` and `.tertiary`,
  not Onyx, Slate or Faint. Content on an opaque fill keeps its token.
- R6: No text is smaller than 12 pt. Use `.caption` as the smallest style.
- R7: Spacing comes from stack `spacing:` with a `Space` token, not from per-element padding.
- R8: Nothing inside a card has a shadow. Depth exists only where a surface floats over the map.
- R9: Apply Liquid Glass with `goraGlass(_:tint:fallbackColor:in:)`, not `glassEffect(_:in:)`. The
  modifier reads the Liquid Glass toggle in `Settings.bundle`. When the toggle is off, it draws the
  tint as a solid fill, or the `fallbackColor:` argument when the glass has no tint.
  `fallbackColor:` is `Color.vellum` by default. The fill has `cardShadow(y: 0)`, so the surface
  shows above the map. Put a tint in the `tint:` argument, not in the `Glass` value, so the
  fallback can show it.

## Known exceptions

| Where | Value | Reason |
|---|---|---|
| `StationAccessPoint.directionTint` | Licorice, `Color(white: 0.38)`, `Color(white: 0.52)` | A fixed white symbol sits on the fill in both modes. Onyx turns white in dark mode. |
| `GoraLiveActivity/LiveActivityPalette.swift` | Hex values | The widget extension does not share the app's asset catalog. |
| AR survey sign panels | White text on the kind color | Low contrast on Tangerine and Jade. Open follow-up. |
| Primary action in dark mode | White on Cobalt #5B9DFF, 2.7:1 | The CTA keeps the Search Route colors in both modes. Open follow-up: a darker dark value or dark text. |
| Secondary action on dark glass | Cobalt #5B9DFF on Haze over dark glass (#4D5C73), 1.99:1 | The secondary label uses the primary blue, as the design canvas asks. Add Place on the map is the only secondary button on glass. Open follow-up: a darker fill under Add Place in dark mode. |

## Location-off motion

Every Location-off animation lasts `Motion.locationStateDuration` (0.3 s) and uses `Motion.locationState`.
This covers the banner, the step change in the commute card, the row state, the map leg opacity and width,
and the switch back to live guidance. `Motion.locationBanner(from:reduceMotion:)` moves the banner from its
edge with a fade. With Reduce Motion it fades only, and the map leg width changes at once. System alerts and
menus keep their system animation.
