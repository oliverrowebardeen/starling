# ADR 0015: Home, New, Friends, You

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

The Phase 1 app opened on a Down settings form. Phase 1.5 section 7 and the six mockups define a new structure. The tab bar holds Home, Friends, and You in a Liquid Glass bar, with a separate circular New (+) button, and system components only, with no hand-rolled glass.

Two primary-source findings (2026-09-30):

- **iOS 27 `TabRole.prominent`.** "Only one tab can receive the prominent treatment. When there are no tabs with an explicit `.prominent` role, then a `.search` role tab may receive the prominent visual treatment by default." iOS 26 introduced the separated search tab (`Tab(role: .search)`). Every `Tab` has content; there is no action-only tab.
- **HIG, Tab bars.** "Use a tab bar to support navigation, not to provide actions… use a toolbar instead."

## Decision

1. **Home** is the inbox of interactions in three sections: Needs you, In progress, and Coming up (ADR 0011). Finished interactions are reached from a plan or from Friends. The status mark at the top shows the agent's overall state, with a plain line such as "Your agent is working on 2 things". Home replaces the Down tab.
2. **New** is `Tab(role: .prominent)`, so it takes the separated circular slot beside Home, Friends, and You. It is a navigation destination whose screen is the composer, not an action button.
   - The composer has the free-text field, "Starling understood" chips (editable), the audience picker, skill tiles, and a primary button labeled by the skill: "See who's up for it" for Down for….
   - The mockup's "Cancel" clears the draft and returns to the previous tab.
   - A New tab keeps the draft while the owner looks at Home.
3. **Friends** lists pairings with each friend's pair symbol, per-friend history and supported skills (from their card), and Add friend, which is pairing in person.
4. **You** shows:
   - the agent: where its model runs, and the on-device-only policy;
   - the privacy topics (ADR 0014);
   - each skill, with its permission line and switch (ADR 0013);
   - the rules.
5. **Developer is Debug-only**, as a section at the bottom of You, not a tab. The "this test build does not hide free times" notice moves there. Release builds have no Developer section and no test-build notices, and a CI check in the style of ADR 0140 guards this.
6. **System components and Liquid Glass.** `TabView` with `Tab`, sheets, toolbars, and system button styles provide the glass; the app does not draw its own. The status mark is drawn live by `StarlingDesign` and is never rendered with `glassEffect` or `GlassEffectContainer` (brand instructions, ADR 0172).
7. **Appearance.** The app follows the system's light or dark setting. Designs are drawn light first, and every screen has a dark version from the brand tokens (DESIGN.md).

## Consequences

- Because only one tab can be prominent, Starling cannot also have a separated Search tab. If search is needed later, it goes inside Home or Friends.
- New as a tab is reachable from anywhere in one tap, and its draft survives switching tabs, which a modal sheet would lose.
- Lane A rebuilds the app shell. Phase 1's Down, Rules, and Pairing screens become parts of New, You, and Friends.

## Sources

- `TabRole.prominent`: https://developer.apple.com/documentation/swiftui/tabrole/prominent
- WWDC26 session 269 (SwiftUI updates): https://developer.apple.com/videos/play/wwdc2026/269/
- WWDC25 session 256 (search tab role): https://developer.apple.com/videos/play/wwdc2025/256/
- HIG, Tab bars: https://developer.apple.com/design/human-interface-guidelines/tab-bars
- Phase 1.5 prompt, section 7; mockups "Home", "New", and "You"
