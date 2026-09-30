# Phase 1 device checklist: BR (Brand and app icon)

One iPhone on iOS 27 (Phone A). Reference images: `docs/brand/previews/`.

## Setup

1. Mac: `xcodegen generate --spec App/project.yml`, open `App/Starling.xcodeproj`, run the Starling scheme on Phone A. Expect: the build installs and the Home Screen shows the Overlap icon, not a blank white icon.

## App icon on the Home Screen

To switch appearance: touch and hold the Home Screen background, tap Edit, then Customize.

2. Customize > Default (light). Expect: cream background, dark blue shape top left, lighter blue shape bottom right, and the overlap between them shows plain cream with no grey smudge along its top edge. Compare with `previews/icon-default.png`.
3. Customize > Dark. Expect: near-black background, brighter blue top left, deeper blue bottom right, the overlap shows the near-black background. Compare with `previews/icon-dark.png`.
4. Customize > Clear > Light, then Clear > Dark. Expect: two translucent grey shapes, each with its own rim, the lower right one slightly lighter; the overlap shows through to the wallpaper like the rest of the background.
5. Customize > Tinted, keep the default tint, then Light and Dark. Expect: the two shapes are two different shades of the tint in both. Tinted Dark is the weakest case (measured 1.11:1); report if the shapes read as one blob at arm's length.
6. Tinted again, drag the color slider to red, then to green. Expect: still two distinct shades each time.
7. Default appearance: swipe down on the Home Screen to open Search and type "Starl". Expect: the small icon in the result still shows a hole between the shapes (it may read as an "S"), not a filled blob.
8. Settings, scroll to Apps, find Starling. Expect: the small icon matches the Home Screen icon.

## Status mark (Xcode Previews on the phone)

The app does not show the mark yet (`docs/requests/BR.md`, item 1). Until lane H links it, use previews:

9. Mac: open `Packages/StarlingDesign/Package.swift` in Xcode, open `StatusMark.swift`, show the canvas, select the "States" preview, and pick Phone A in the canvas's device menu. Expect: the mark and a segmented control appear on Phone A within about 30 seconds.
10. Phone A: tap `searching`. Expect: the shapes move toward a new spacing, the top left shape gently breathes, and both wander a little. Nothing jumps.
11. Tap `negotiating`. Expect: the shapes slide together in under a second and a transparent gap opens between them (the page background shows through, never a third color).
12. Tap `match`. Expect: as the shapes settle, the gap fills with pale light, which fades within about 2 seconds. The resting mark looks exactly like the Home Screen icon's shapes.
13. Tap `noMatch`. Expect: the shapes drift apart and the bottom right one fades to faint. No sound, no vibration, no text.
14. Tap `idle`, then `negotiating`, then `idle` quickly, before each move finishes. Expect: every change starts from where the shapes are; no snapping.
15. Mac: select the "States, dark" preview. Phone A: repeat steps 11 and 12. Expect: brighter blue top left, deeper blue bottom right, the gap shows the dark background, and a white light on match.
16. Phone A: Settings > Accessibility > Motion > Reduce Motion on. Mac: reselect the "States" preview. Phone A: tap through every state. Expect: each change is a quick crossfade (about 0.3 seconds), with no sliding, breathing, or wandering. On `match` the light still appears in the gap and fades.
17. Phone A: turn Reduce Motion off, turn VoiceOver on, touch the mark in each state. Expect: "Starling" for idle and noMatch, "Looking for a match" for searching, "Agents are talking" for negotiating, "Matched" for match.
18. Mac: select the "Still poses" and "Dynamic Island sizes" previews. Expect: apart, close, and logo poses, each with a clean transparent gap where the shapes overlap, including at 22 points on black.
