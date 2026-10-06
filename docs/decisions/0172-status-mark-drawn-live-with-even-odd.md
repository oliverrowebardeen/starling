# ADR 0172: Status mark drawn live with an even-odd knockout, in its own package

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-09-30
- Owner: BR (Brand and app icon)

## Context

The app needs an animated version of the Overlap mark to show Down status: idle, searching, negotiating, match, and no match. The owner's brief sets the rules: the overlap is knocked out as a rule, not a stored cutout, so it works at any shape position; no `glassEffect` or `GlassEffectContainer` (glass shapes merge when close and would fill the gap); Reduce Motion crossfades; static poses for a future Dynamic Island; a match ends in the app icon's pose. The owner's HTML motion reference (`starling_logo_status_animation.html`) gives per-state offsets, drift, pulse, and fade values.

## Decision

1. **A new package, `Packages/StarlingDesign`,** with no dependency on `StarlingCore`. The mark is shared UI, not a StarlingKit building block, and lane H can adopt it without pulling in anything else. `Tools/test-all.sh` picks it up automatically.
2. **Geometry and timing are plain values** (`MarkGeometry`, `MarkPose`, `MarkFrame`, `MarkTransition`), pure functions of time. Units match the icon: 40 by 56 shapes, radius 14, rotated 20 degrees, canvas side 1024 / (123.29 / 14) units. A test checks the logo pose against anchor points in the icon's SVG layers.
3. **The knockout is the even-odd fill rule.** Each shape is masked by a large rectangle plus the other shape, filled even-odd, so the other shape's area is empty. It is recomputed every frame from the current positions. The match light is the second shape clipped to the first, so it can only appear inside the gap.
4. **Plain SwiftUI shapes, not `Canvas`.** The same `MarkGlyph` draws the animated mark and the still poses (`StaticMarkPose.apart`, `.close`, `.logo`), so the still poses need nothing beyond shapes, fills, and masks when a Live Activity adopts them.
5. **Motion:** 0.8 s cubic ease in and out between poses, retargeted from the current pose so an interrupted move never jumps. Searching: your shape (A) breathes by 4 percent and the separation drifts by up to 5 units. Negotiating drifts by 1.2 units. Match: light rises in the gap over the last 0.2 s of the move, then fades over 1.6 s, leaving exactly the logo pose. No match: the shapes separate beyond idle and the other person's shape (B) fades to 25 percent, as in the reference. No sound and no message; VoiceOver reads "Starling" for both idle and no match.
6. **Reduce Motion:** the shapes hold each state's pose with no drift or pulse, and a state change is a 0.3 s crossfade. The match light still rises and fades, because it changes opacity, not position.
7. **Battery:** the `TimelineView` pauses once the mark settles (idle, match after the light, no match). Searching and negotiating redraw continuously while they last.

## Consequences

- The mark cannot drift from the icon without a test failing.
- Lane H decides where the mark appears in the app. That needs `StarlingDesign` added to `App/project.yml`, which lane H owns; the request is in `docs/requests/BR.md`.
- Until then, the owner sees the mark on a phone through Xcode Previews on a device (`docs/checklists/phase-1-BR.md`).
- The rendering tests use `ImageRenderer` on macOS, so they need a macOS host with a window server. That holds for local runs and GitHub's macOS runners.

## Sources

- Apple, `ImageRenderer`: https://developer.apple.com/documentation/swiftui/imagerenderer
- Apple, `FillStyle` (`isEOFilled`): https://developer.apple.com/documentation/swiftui/fillstyle
- Apple, `TimelineView` and `AnimationTimelineSchedule` (`paused`): https://developer.apple.com/documentation/swiftui/timelineview
- Apple, `EnvironmentValues.accessibilityReduceMotion` (read only, so previews use an explicit override): https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
- Apple, "Creating your app icon using Icon Composer" (Liquid Glass groups and layers): https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- The owner's motion reference: an HTML animation prototype (not in the repo).
