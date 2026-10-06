# ADR 0171: App icon group shadow at 20 percent

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-09-30
- Owner: BR (Brand and app icon)

## Context

The owner's icon bundle (`Starling_icon_v2.zip`) gives the "Overlap" group a neutral shadow at 50 percent opacity. The brief asks to check that this shadow does not darken or muddy the knocked-out gap, because the empty gap is the point of the mark: nothing is shared until both people say yes.

The gap is enclosed by shape A above and shape B below. Liquid Glass casts the group shadow downward, so A's shadow falls into the top of the gap. Rendered with Icon Composer's `ictool` (Xcode 27.0, `--platform iOS --rendition Default`, 1024 px), measured inside the gap 8 px in from its edge against the icon background (#FAF9F6):

| Shadow opacity | Gap dE p95 | Gap dE max | Gap pixels darker than background (L* below by more than 2.3) |
|---|---|---|---|
| 0.5 (as delivered) | 5.2 | 6.9 | 23.7% |
| 0.4 | 4.2 | 5.6 | 20.7% |
| 0.3 | 3.1 | 4.2 | 15.9% |
| 0.25 | 2.7 | 3.5 | 10.9% |
| **0.2** | **2.1** | **2.9** | **2.3%** |
| 0.15 | 1.7 | 2.5 | 0.0% |
| 0.1 | 1.1 | 2.0 | 0.0% |
| 0.0 | 0.7 | 1.1 | 0.0% |

dE is CIELAB Delta E 1976, where about 2.3 is a just noticeable difference. At 50 percent, about a quarter of the gap is visibly grey in the light appearance (`docs/brand/previews/shadow-gap-0.5-vs-0.2.png`). The dark appearance was already clean at 50 percent (p95 1.5, no darker pixels), because a neutral shadow barely shows on #141418. The clear and tinted appearances were clean too.

## Decision

Set the group shadow opacity to 0.2 for every appearance. It is the highest value in the sweep where the 95th percentile of the gap stays under one just noticeable difference and fewer than 5 percent of gap pixels read as shadowed. Kind stays `neutral`; nothing else in the bundle changes.

One value rather than a per-appearance specialization: dark mode gains nothing visible from the extra shadow, and one value is easier to keep right when the owner edits the bundle in Icon Composer.

## Consequences

- The shapes sit a little flatter on the light background. The shadow under shape B is still visible, so the icon keeps some depth.
- `python3 docs/brand/tools/icon_previews.py` re-renders all six appearances and reruns this sweep, so a future edit can be checked the same way.
- If the owner wants more depth, 0.25 is the next step up and puts about 11 percent of the gap under a visible shadow.

## Sources

- Apple, "Creating your app icon using Icon Composer" (Liquid Glass shadow, specular, and appearance settings): https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- `ictool` usage, from `Icon Composer.app/Contents/Executables/ictool` in Xcode 27.0 (27A266a), bundle version 129.
- CIE 15:2004 Colorimetry (CIELAB); Sharma, "Digital Color Imaging Handbook" (2003), for Delta E 2.3 as a just noticeable difference.
