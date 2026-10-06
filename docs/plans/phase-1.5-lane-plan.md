# Phase 1.5 lane plan

Status: **Approved by the owner on 2026-09-30**, with all six lanes starting together. Kickoff prompts: `docs/plans/phase-1.5-kickoff-prompts.md`.

Scope and exit criteria: `docs/plans/phase-1.5-prompt.md`. Decisions: ADRs 0010 to 0018. Interfaces: Core v2, frozen on main at c07c036 (PR #45, after five adversarial review rounds).

## 0. Before lanes start

| # | Item | Who | Why |
|---|---|---|---|
| 1 | ~~Merge Core v2 (PR #45)~~ Done, c07c036 | Orchestrator | Lanes build on the frozen interfaces |
| 2 | ~~Agree or redirect ADRs 0010 decision 2, 0013, and 0018~~ All three approved | Owner | Lanes A, B, C, and E build on these |
| 3 | ~~Say what Muse and Dots are, or drop them from hand-offs~~ Out of scope (ADR 0018) | Owner | Hand-off scope |
| 4 | Restore hosted CI (not running again since about 02:52Z on 2026-10-01) | Owner | CI is the merge gate; until then the Orchestrator gates locally (ADR 0007) |
| 5 | Enable the Wi-Fi Aware capability for `com.oliverrowebardeen.starling` and sign in again in Xcode | Owner | Signed device builds with Wi-Fi Aware, needed for the exit test |

## 1. Lanes

Six lanes in parallel, as the prompt proposes, with paths matched to the repo. Every lane follows AGENTS.md and ends with DONE or BLOCKED, a device checklist, and `Tools/local-gate.sh` passing.

| Lane | Owns | Delivers | Acceptance (without a device unless noted) | Agent |
|---|---|---|---|---|
| **A. Shell and IA** | `App/`, plus additions to `Packages/StarlingDesign/` (pair symbols, plan-word VoiceOver labels) | Home, New (prominent tab), Friends, You, Developer section (Debug only); the lifecycle coordinator and a persistent `InteractionStore`; shared components: consent sheet, status card, proposal card, confirm, Keep it going list, plan timeline, egress audit; privacy topics in You replacing Phase 1's sharing rows; Local Network and notifications asked at first use; hand-offs (ADR 0018); roster rows with pair symbols and nickname hygiene (issue #46) | Feature tests drive every screen with `ScriptedSkillService` and `SampleSkills`; the coordinator applies every `SkillEvent` correctly, including invalid ones; Release has no Developer section or test-build notices (CI check); the app builds | Claude |
| **B. Down for… skill and the model** | `Packages/Skills/DownFor/` (new), `Packages/StarlingNegotiation/` (Down moves out or becomes shared building blocks), `Packages/StarlingAgent/` (`SkillModel`) | Phase 1 Down as the first `SkillService`; `SkillModel.route`, `.intent`, `.proposalText` in StarlingAgent with runtime schemas (ADR 0016); template fallbacks; plan wording (ADR 0017); removal request for Core's Down facade | Loopback scenarios: mutual plan, nobody up, passes, unsupported peer; routing and chip accuracy measured on labeled sets (macOS baseline, then iOS 27 device) | Claude |
| **C. Find a time** | `Packages/Skills/FindATime/` (new), `Packages/StarlingAvailability/` (new: EventKit busy and free, stated intent, ask-owner) | Busy and free from EventKit full access after Starling's sheet (ADR 0013); ask-owner fallback through `SkillQuestion` on denial or no calendar; produces `TimeSlot` and `Plan`; the calendar purpose string | Calendar and no-calendar agents agree on a time over Loopback; denial still completes; event titles, places, and attendees never reach a send or a prompt (tests) | Claude |
| **D. Pick a place** | `Packages/Skills/PickAPlace/` (new) | Accepts `Plan` or `TimeSlot`, produces `PlaceChoice`; MapKit search near a typed area without permission, nearby with Location When In Use at first use; manual entry; private aggregation of budget and diet; how the model sees venue names, if at all (ADR 0012) | Group of 3 agrees on a place over Loopback; a hostile venue name never reaches a prompt as instructions; location denial still completes | Claude |
| **E. Chaining and audit** | `Packages/StarlingChaining/` (new), `Packages/Skills/SwapPhotos/` (new, flagged off) | Chain suggestions from the registry, per-link consent from `SkillExposure`, time-triggered chains with the opt-in recorded, "How this came together" and "What left your phone" from `Interaction` history and egress (an `OutboxObserver` that records `EgressRecord`s); Swap photos proves the after-plan-ends hook | Down for… to Pick a place chain with a fresh consent only when a topic is added; unsupported chains hidden; egress log equals what the consent sheet showed | Claude |
| **F. Red team** | `Tools/Simulator/Scenarios/`, test targets only; files issues | Injection through chained skills and venue names; a peer trying to start a skill, a permission, or a chain (`chainedFrom`); denied-permission paths; peers missing a skill or version; replays and stale revisions against the lifecycle; roster substitution on the consent sheet (issue #46) | Every scenario passes or has a filed issue with a reproduction | Codex (an independent model is a better adversary) |

Phase 1 lanes not listed here are complete. On approval, the Orchestrator updates AGENTS.md's ownership table with these paths and writes each lane's kickoff prompt, as in Phase 1.

## 2. Order and dependencies

- B, C, D, and E start together against Core v2 and the fakes. A starts at the same time and wires each skill as it merges, as lane H did in Phase 1.
- Merge order: B (Down for…, which the exit test needs first), then C, D, and E in any order, then A's integration PRs, with F last.
- Interface changes go through `docs/requests/<lane>.md` and the Orchestrator, as before (ARCHITECTURE section 4).

## 3. Exit criteria, as adjusted

The prompt's section 12, on two real iPhones, with criterion 7 changed by the owner's clarification: no screen reads like a dating app, and no Down screen lacks an activity, checked by eye on the device checklist (ADR 0017). Criterion 5 follows ADR 0013 once the owner agrees.

## 4. Risks

- **The iOS 27 on-device model is new.** Routing and chips are measured on the macOS 26.7 model first. The device numbers decide whether New leads with free text or with tiles.
- **Hosted CI is off.** Six lanes push often. Until CI runs again, merges wait on the local gate, which checks one branch at a time.
- **The device test needs two people.** The owner and a friend run the checklists. Everything before that is covered by Loopback and the simulator.

## 5. Queued for after Phase 1.5

The owner queued these on 2026-10-01, to plan once this run is done. Each gets its own ADRs and lane prompt.

### Pairing methods, as its own lane

Updated by the owner later on 2026-10-01; this replaces the earlier note that treated links as unverified requests.

- **Remote pairing by link is first-class.**
  - The link carries the public key fingerprint and a one-time token, and is shared through any existing channel (Messages, Instagram, and so on).
  - Trust on first use.
- **Security comes from key-change detection.** If a paired friend's key changes, show a clear warning and require re-confirmation before any negotiation continues.
- **In person stays the fastest.**
  - In-person QR and the nearby flow remain the quickest options when together.
  - "Verify in person" is an optional upgrade on the friend's page.
  - No badges or warnings for unverified friends in normal UI.
- **The owner stays in control.** Links are single-use or expiring, and the owner approves incoming link requests.
- **No discovery by phone number or contacts.** That would need accounts and a server directory.
- **An App Clip** for the link flow when available.

### Onboarding and personalization

Principle: the agent knows preferences and constraints, not the user's life. Starling combines private data, untrusted peer content, and external communication by design, so it minimizes what the agent knows.

- **About you card.**
  - The agent's only personal memory: a short, editable list of facts, each with its source and a delete control.
  - Negotiation context may include only card facts, filtered by privacy topics.
- **Sources for card facts:**
  1. Onboarding answers and plain-language notes, parsed by the on-device model and confirmed by the owner.
  2. Optional on-device imports, offered just in time:
     - calendar rhythms (with Find a time);
     - photo metadata places and food (opt-in);
     - Apple Music taste;
     - Contacts for pairing suggestions (limited access is fine).

     Raw data is never stored or sent, only summaries the owner approves. Private Cloud Compute is allowed for heavy passes, never third-party cloud models.
  3. Learning from use, always proposed as a one-tap confirmation.
- **Out of scope for v1:**
  - Messages access (not available to third-party apps).
  - Gmail (restricted scope, verification and a security assessment at scale).
- **Siri.** Skills are exposed through App Intents, so Siri can pass in-context information (for example from a group chat) into a single request.
- **Onboarding:** three screens, under 60 seconds, zero permission prompts.
  1. Name and pair symbol reveal.
  2. "What are you usually up for?": activity chips, a comfortable spend range, a rough area as text (no GPS), and an optional free-text note parsed into card entries.
  3. Add your first friend: QR or nearby, with a "Send a link" fallback (App Clip when available).

  Then land on Home with a suggested first action ("Post your first Down for…"). All permissions stay just in time, per skill.

### To settle when these are planned

These touch current decisions or depend on facts to re-verify against primary sources first (AGENTS.md).

- **Pairing by link changes the trust bootstrap.**
  - Brief 2.2 ("Pair in person, coordinate anywhere") and ADR 0102 make being together the trust bootstrap; trust on first use over a link replaces that as the default.
  - That needs a brief update and an ADR, plus the threat model's view of a link shared through a channel someone else controls.
  - ADR 0003's pinned keys already give key-change detection a base.
- **Onboarding replaces ADR 0202's "no onboarding" (lane A).** The zero-prompt rule matches ADR 0202's Local Network and notifications at first use.
- **A "pair symbol reveal" for the owner** needs a definition. DESIGN.md section 4 gives each friend a pair symbol of the pair, not one per person.
- **The About you card becomes the only owner context in prompts.**
  - That narrows PromptRenderer and ADR 0016's intent inputs.
  - The card's facts need topics (ADR 0019), so Never keeps a card fact out of negotiation.
- **Imports and model location to verify first:**
  - Whether third-party apps can use Private Cloud Compute, as opposed to the on-device Foundation Models framework.
  - What MusicKit exposes for taste.
  - The photo metadata APIs under limited library access.
  - The Contacts limited-access picker.
  - The App Clip and link (universal link) flow.
