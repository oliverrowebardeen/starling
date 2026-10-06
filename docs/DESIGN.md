# Starling design

Owned by the Orchestrator. Lanes that build screens read this with `docs/brand/README.md`. Decisions behind it live in ADRs 0013 to 0018 and 0170 to 0172.

Status: **Phase 1.5.** Created 2026-09-30. The Phase 1.5 prompt referred to this file before it existed; it now collects the design rules from that prompt, the brand lane's work, and the owner's six mockups.

## 1. Principles

- **Plans with friends, not a dating app.** Plan words, an activity on every Down for…, real friends on every request (ADR 0017).
- **The action first.** Home opens on what needs the owner, and New is one tap away. No screen opens on a settings form (ADR 0015).
- **Show what leaves the phone.** Consent before, "What left your phone" after, both from the same items (ADRs 0011 and 0014).
- **System components.** Liquid Glass comes from `TabView`, sheets, toolbars, and system button styles, never drawn by hand (ADR 0015).

## 2. Tokens

From `docs/brand/README.md`. `StarlingDesign.MarkPalette` is the code version, and a test checks contrast.

| Token | Light | Dark |
|---|---|---|
| Shape A (you) | `#1F4FE0` | `#5B85FF` |
| Shape B (the other person) | `#5F80EE` | `#3F63D6` |
| Background | `#FAF9F6` | `#141418` |
| Lit overlap (status mark only) | `#9DB8FF` | `#FFFFFF` |

The app follows the system appearance. Screens are designed light first, and every screen has a dark version from these tokens. Text and controls use system colors and Dynamic Type.

## 3. Logo and status motion

The mark is the Overlap: two rounded rectangles whose overlap is cut out. Starling shares only the overlap, and nothing until both say yes (brand README). In the app it is always drawn live by `StarlingDesign.StatusMark(state:)`, never from the SVG, and never with `glassEffect` or `GlassEffectContainer` (ADR 0172).

| `MarkState` | Motion | Used for |
|---|---|---|
| `idle` | Two shapes, apart | Nothing in progress |
| `searching` | Your shape pulses; both drift | A request is out (In progress) |
| `negotiating` | The shapes slide in; the gap opens | Agents are working, only where the signal does not reveal one-sided interest (brand request 1) |
| `match` | The gap fills with light, then rests as the logo | It's a plan |
| `noMatch` | The shapes drift apart; the other fades | Ended with nobody up: no sound, no message |

Where the mark appears:

- **Home's header** shows the agent's overall state ("Your agent is working on 2 things").
- **Each In progress row** shows that interaction's state.
- **It's a plan** opens on the lit logo.

VoiceOver labels use plan words: "Checking with friends", "Agents are talking", "It's a plan", and "Starling" for idle and no-overlap. These replace Phase 1's "Looking for a match" and "Matched" (ADR 0017).

## 4. Pair symbols for friends

Every friend has a pair symbol: the Overlap mark in a color pair of its own (mockup "New", the row of friends). Rules:

- **Derived, not chosen.** The color pair comes from the friend's `PeerID`, which is a hash of their key, picked from a curated set of hue pairs that keep both shapes at least 3:1 against the background in light and dark. A peer cannot choose its own symbol.
- **Stable.** The same friend has the same symbol everywhere in the app.
- **Yours is the brand pair.** Shape A and B blue.
- **Decorative, not a security signal.** The code comparison at pairing verifies a friend (ADR 0101); the symbol only helps recognition.

`StarlingDesign` provides it as a view taking a seed, and the app passes the `PeerID`. The palette is the shell lane's to design within these rules.

## 5. Screens

Mockups are in `docs/design/phase-1.5/` (exported from Claude Design on 2026-09-30). Treat them as layout and content guidance, not pixel specs.

| Mockup | File | Notes |
|---|---|---|
| Home: inbox across skills | `home.png` | Needs you, In progress, Coming up. Decline note per ADR 0017: "If you pass, they just won't see it." |
| New: composer routes to a skill | `new.png` | Free text, "Starling understood" chips with Edit, Ask (All friends / Close friends / Pick) with pair symbols, skill tiles, primary button. New is a prominent tab (ADR 0015). |
| Just-in-time permission: Find a time | `find-a-time-permission.png` | Keep the three-row explanation. One "Continue" button before the system alert (ADR 0013, approved by the owner). |
| It's a plan: chained skills | `its-a-plan.png` | Lit logo, plan card, "Keep it going": Add to Calendar, Swap photos after (only when its flag is on), Somewhere else?, Message the group. |
| Plan detail | `plan-detail.png` | Message group, Directions, "How this came together", "What left your phone": shared versus kept on your phone. |
| You: privacy topics and skills | `you.png` | Agent card, topics with Share / Ask me / Never, skills with permission lines and switches. The time and activity note per ADR 0017. Swap photos appears only when its flag is on. v2.1 (ADR 0019): location and calendar details join the topics, each choice shows its one-line explanation on the control, and the defaults are the protective ones. |

Shared lifecycle components, built once and used by every skill (ADR 0011):

- consent sheet
- status card
- proposal card
- confirm
- Keep it going list
- plan timeline
- egress audit

## 6. Accessibility

- Every mark has a VoiceOver label (section 3), and decorative pair symbols are hidden from VoiceOver next to the friend's name.
- Status motion respects Reduce Motion: the mark crossfades between states' resting poses instead of moving (`StarlingDesign.MarkMotion` already does this).
- Shapes meet 3:1 against the background in both appearances, and text uses system colors.
