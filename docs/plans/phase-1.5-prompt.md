# Starling Phase 1.5: From a Down app to an agent interaction platform

Oliver's Phase 1.5 prompt, 2026-09-30, kept as written below this note. Where it and an ADR differ, the ADR wins:

- **Intent schema** (section 2): data in `IntentSchema`, turned into a guided-generation schema by StarlingAgent at runtime, not an `@Generable` type in each skill. ADR 0010, decision 2; Proposed until Oliver agrees.
- **Pre-permission sheet** (sections 5 and 10.3): one "Continue" button before the system alert, per the HIG. "Just ask me" is the fallback on denial and a switch in You. ADR 0013; Proposed until Oliver agrees.
- **Banned words** (section 9, exit criterion 7): Oliver clarified on 2026-09-30 that the goal is not looking like a dating app, not a word list, and that a crush skill could come later. Tone is reviewed by eye (ADR 0017).
- **New (+) button** (section 7): a `Tab(role: .prominent)` whose screen is the composer. iOS has no action-button tab, and the HIG reserves tab bars for navigation. ADR 0015.
- **Message the group** (section 4): Starling has no phone numbers. The owner may link a friend to a contact on this phone. ADR 0018; Proposed until Oliver agrees.
- **Muse and Dots** (section 3): open question. They are not in the brief or the repo.
- **DESIGN.md** did not exist when the prompt was written. It now does (`docs/DESIGN.md`).

---

You are the Orchestrator for Starling. Read docs/BRIEF.md, docs/ARCHITECTURE.md and docs/DESIGN.md before doing anything. This prompt supersedes them wherever they conflict; fold its decisions into those docs as ADRs and doc updates before any lane starts.

Status: still ideation-grade. These are researched defaults. If you find something better, propose it with primary sources and a clear tradeoff, then proceed once Oliver agrees.

Owner norms (unchanged): no sycophancy, push back when warranted; no em dashes in any prose you write (docs, UI copy, commit messages); cite primary sources.

## 1. Why this phase exists

Phase 1 shipped working plumbing (pairing, policy, consent, Down over a simulated friend). A device review found three problems:

1. The whole app is built around Down. It must become a platform where Down is one skill among several.
2. The main screen reads like a dating app ("Down?" with no activity, "How keen are you?", "only if they're interested too") and opens on a settings form instead of the action.
3. The on-device model does almost nothing in the core loop. It only turns rules text into rules, which a form does better.

This phase fixes all three before any new feature work.

## 2. Core concept: skills

- Starling is an agent interaction platform. Features are **skills**: Down for…, Find a time, Pick a place, Swap photos, and later Gift pool, Vouch, Keep in touch, etc.
- StarlingKit defines a `StarlingSkill` protocol. A skill provides only what is unique to it:
  - `id` and `version`
  - an intent schema (`@Generable`) the model extracts from free text
  - the negotiation building block it uses: private aggregation, mutual reveal, private query, negotiation with private limits, or matched exchange
  - the privacy topics it touches, and which of those are required
  - the system permissions it may need (see Section 5)
  - the artifacts it **accepts** and **produces** (see Section 4)
  - proposal wording and a proposal renderer
- Each skill is its own Swift package and is feature-flagged. **v1 enables: Down for…, Find a time, Pick a place.** Swap photos ships as a flagged-off skill in this phase only far enough to prove chaining hooks.
- Each agent's card advertises supported skills and versions (this mirrors A2A, where `AgentCard.skills` is a required field). If a peer lacks a skill or version, fail gracefully with a clear message ("Maya's Starling doesn't do this yet").
- Message envelopes carry skill id and version.

## 3. One lifecycle for every skill

Compose (intent + audience) -> Consent (what leaves the phone) -> Negotiate (status motion) -> Propose (one card) -> Confirm (both humans) -> Hand off (calendar, Messages, Maps, Siri/Muse/Dots) -> Remember (history and audit).

Build each step as a shared component. Skills plug into these components; they never build their own screens for these steps. An `Interaction` model in the store tracks: skill, participants, state, timestamps, chain links, and the egress log.

## 4. Skill chaining

Skills connect through typed **artifacts** defined in StarlingCore:

| Artifact | Meaning | Produced by | Accepted by |
|---|---|---|---|
| `Plan` | who + activity + time (+ place if known) | Down for…, Find a time | Pick a place, Swap photos, Add to Calendar, handoffs |
| `TimeSlot` | an agreed time window | Find a time | Down for…, Pick a place |
| `PlaceChoice` | an agreed venue | Pick a place | `Plan` (updates it), handoffs |
| `Attendees` | the confirmed people | any skill that confirms a group | Swap photos, Message the group |

Rules:
- **Suggested chains** appear at Confirm as "Keep it going" (see the It's a plan mockup): Add to Calendar, Somewhere else? (Pick a place), Swap photos after, Message the group.
- **Time-triggered chains**: a skill may schedule itself relative to a `Plan` (Swap photos starts when the plan ends). It still requires the user's explicit opt-in at Confirm.
- **Consent per link**: a chained skill that touches a new privacy topic or a new system permission must run Consent again. Never auto-run a skill that adds a new topic or permission without a tap from the user.
- Every link is recorded on the plan's timeline ("How this came together") and in its egress log ("What left your phone").
- Peers must support the chained skill; otherwise the suggestion is hidden for that group, not shown and failed.

## 5. Permissions belong to skills, requested just in time

Apple's guidance: request permission only when the app clearly needs it, ideally when the person actually uses the feature that requires it. So nothing is requested at launch.

| Skill or action | Permission | When requested | If denied |
|---|---|---|---|
| Down for… | none | n/a | n/a |
| Add to Calendar | none: use `EKEventEditViewController`, which adds events without requesting access | n/a | n/a |
| Find a time | EventKit **full access** (reading events requires full access; there is no read-only level) | first time the user starts Find a time | fall back to "Just ask me instead": the agent asks the owner one quick question |
| Pick a place | Location When In Use | first time the user lets the agent suggest nearby places | user types or picks a place manually |
| Swap photos | PhotoKit | after a plan ends, only if the user opted in at Confirm | skill stays off; respect limited library access by offering only the photos the user selected |

- Before each system prompt, show Starling's own pre-permission sheet (see the Find a time mockup): what the agent reads, what never leaves the phone, what the friend sees, a primary "Use my calendar" (or equivalent), and a "Just ask me instead" fallback.
- Find a time reads busy/free only. Event titles, locations and attendees never leave the device and never enter a prompt sent to a peer.
- Purpose strings in Info.plist must be specific to the skill's use ("Starling checks when you're busy so friends' agents can find a time without asking you. Event details stay on your iPhone.").
- The You tab shows each skill's permission state and lets the user switch skills off.

## 6. Privacy topics (global)

- Topics: time, activity, place, budget, diet, people, photos, interests. One control per topic: **Share / Ask me / Never**, applied across all skills.
- Time and activity are always shared as the overlap (nothing can match without them), so they have no Never option; say so in one line.
- Skills declare the topics they use. If a required topic is set to Never, the skill explains why it can't run instead of failing silently.
- Remove the Phase 1 "Never share X" toggle + "Otherwise" picker pattern entirely.

## 7. Information architecture

- **Home**: inbox of interactions grouped as Needs you / In progress / Coming up. The logo at the top shows overall agent status. Replaces the Down tab.
- **New (+)**: composer. The user types anything; the on-device model routes it to the right skill and shows what it understood as editable chips. Skill tiles below for tapping. Audience picker (All friends / Close friends / Pick) with friends' pair symbols. Primary button "See who's up for it" for Down; skill-appropriate label otherwise.
- **Friends**: pairings with pair symbols; per-friend history and supported skills; Add friend (AirDrop-style pairing).
- **You**: the agent (where its model runs, on-device-only policy), privacy topics, skills with permission state, rules.
- **Developer**: Debug builds only. Move the "this test build does not hide free times" notice here.
- Tab bar: Home, Friends, You in a Liquid Glass bar, plus a separate circular New (+) button. Use system Liquid Glass components; do not hand-roll glass.

## 8. Put the model in the core loop

- **Routing**: free text in New -> which skill (Down for…, Find a time, Pick a place).
- **Intent parsing**: free text -> structured, editable chips ("boba tonight with whoever's free, nothing far" -> Down for… · Boba · Tonight after 7 · Nearby · Expires in 3 hrs).
- **Fuzzy matching**: "food" matches "boba run"; overlapping windows produce a proposed time.
- **Proposal writing**: "You, Maya and Jake are all down for boba. Boba Guys on Franklin at 8:30?"
- Everything a peer sends stays untrusted input. Typed schemas only; the deterministic policy layer decides egress. Chaining must not let a peer's message trigger a new skill or permission.

## 9. Copy rules (fixes the dating-app read)

- Never show "Down" without an activity. The skill's label is "Down for…".
- Banned in user-facing copy: "keen", "interested", "match", "maybe" on its own, and anything that reads as romantic. Use plan words: "both down", "It's a plan", "up for it".
- Mutual-reveal line: "If nobody's up for it, nobody sees you asked."
- Decline line: "If you pass, they just won't see it."
- Show real friends (pair symbols) wherever a request goes out.
- Light theme by default, full dark mode support. Brand tokens: shape A #1F4FE0 / dark #5B85FF, shape B #5F80EE / dark #3F63D6, background #FAF9F6 / dark #141418. Follow the Logo and status motion section in DESIGN.md.

## 10. Mockups

Oliver has a canvas with six screens for this phase (ask him for exports if you need images):
1. **Home**: Needs you (a Down proposal with I'm in / Not tonight; a Find a time consent request), In progress (Pick a place, Find a time with status marks), Coming up (a plan with a "Photos after" chip).
2. **New**: free-text composer, "Starling understood" chips, audience picker with pair symbols, skill tiles, "See who's up for it".
3. **Just-in-time permission**: Find a time calendar sheet with reads / never leaves / friend sees, "Use my calendar", "Just ask me instead".
4. **It's a plan**: lit logo, plan card, "Keep it going" chain (Add to Calendar, Swap photos after, Somewhere else?, Message the group).
5. **Plan detail**: Message group / Directions, "How this came together" skill timeline, "What left your phone" audit.
6. **You**: agent card, privacy topics with Share / Ask me / Never, skills with permission lines and toggles.

Treat them as layout and content guidance, not pixel specs. Use system components and Liquid Glass where iOS provides them.

## 11. Lane plan for Superset

Run the Orchestrator lane alone first. Spawn the others only after Oliver approves your lane plan.

**Orchestrator (first, solo):** ADRs for Sections 2 to 9; `StarlingSkill` protocol; skill registry and feature flags; artifact types (`Plan`, `TimeSlot`, `PlaceChoice`, `Attendees`); lifecycle state machine and `Interaction` store; global privacy topics in the policy layer; agent card skill advertisement; envelope skill id/version. Freeze these interfaces and merge to main.

Then in parallel:
- **A. Shell and IA**: Home, New, Friends, You, tab bar + New button, shared lifecycle components (consent sheet, status card, proposal card, confirm, keep-it-going list, plan timeline, egress audit). Owns `App/`.
- **B. Down for… skill**: migrate Phase 1 Down into the first skill package; model routing + intent parsing + fuzzy matching + proposal writing; copy rules. Owns `Packages/Skills/Down/`.
- **C. Find a time skill**: EventKit full access via pre-permission sheet; busy/free extraction on device; ask-owner fallback when denied or no calendar; produces `TimeSlot` and `Plan`. Owns `Packages/Skills/FindATime/`.
- **D. Pick a place skill**: accepts `Plan`, produces `PlaceChoice`; location only when used; manual entry fallback. Owns `Packages/Skills/PickAPlace/`.
- **E. Chaining and audit**: chain suggestions, time-triggered chains, per-link consent, timeline, "What left your phone" from the egress log; Swap photos stub skill (flagged off) proving the time-triggered hook. Owns `Packages/StarlingChaining/` and `Packages/Skills/SwapPhotos/`.
- **F. Red team**: prompt injection through chained skills, a peer trying to trigger a skill or permission, denied-permission paths, peers missing a skill version. Owns test targets and simulator scenarios only; files issues instead of editing other lanes' code.

## 12. Exit criteria

On two real iPhones (Oliver runs the device checklists):
1. Typing "boba tonight with whoever's free" in New routes to Down for… and shows editable chips.
2. Both phones go down for overlapping times; Home shows the proposal under Needs you; both confirm; It's a plan appears.
3. Add to Calendar works with no permission prompt.
4. Chaining to Pick a place works and is recorded on the plan timeline; "What left your phone" lists exactly what was shared.
5. Find a time shows Starling's sheet before the system calendar prompt on first use; denying it falls back to ask-owner and still completes.
6. A privacy topic set to Never in You is respected by every skill; a skill that requires it explains why it can't run.
7. No banned words appear anywhere in user-facing copy; no Down screen without an activity.
8. A peer without a skill sees a graceful message; suggestions for unsupported chains are hidden.
9. Red-team scenarios pass.
10. Release builds contain no Developer tab or test-build notices.

When done, report results, open questions, and any place where reality contradicted this prompt.
