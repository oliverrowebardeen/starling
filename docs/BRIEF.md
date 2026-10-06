Starling: Project Brief for Coding Agents

Status: ideation-stage plan, researched late September 2026. Everything here is a default backed by sources, not a commitment. If you find a better approach, propose it with primary sources and a clear tradeoff, then proceed once the owner agrees. Re-verify anything time-sensitive (APIs, SDK versions, library status) before building on it.

> Orchestrator note: Phase 0 verification of Sections 3.1 to 3.6 is in `docs/research/phase-0-verification.md`. Where it contradicts this brief, the ADRs in `docs/decisions/` take precedence. This file is otherwise kept as the owner wrote it, except that personal details were removed before publication.

---

## 0. How to use this brief

- One agent acts as **Orchestrator** (recommended: Claude Opus). It owns this brief, `ARCHITECTURE.md`, the shared interfaces in `StarlingCore`, and merges.
- Other agents (Claude Code or Codex) take **lanes**. Each lane owns specific directories and works in its own Superset workspace (git worktree + branch).
- Worktrees isolate working files but do **not** prevent merge conflicts. Therefore:
  1. At the start of each phase, the Orchestrator freezes the interfaces (Swift protocols and message types) that lanes depend on, and merges them to `main` first.
  2. Lanes branch from that commit and only touch directories they own.
  3. Changes to shared interfaces go through the Orchestrator, never directly from a lane.
- No agent can hold an iPhone. Every lane must be testable without devices (see Section 7), and must end with a short **device test checklist** for the owner to run on real iPhones.

### Running this in Superset

- Parallel workers are not spawned automatically. The Orchestrator may spawn lane workers with the `superset:orchestrate` skill (it uses `superset workspaces create`, `superset agents create`, and `superset terminals read/send`), but only from Phase 1 onward.
- **Phase 0 runs as a single agent, with no fan-out.** Interfaces must exist before lanes can work in parallel.
- Before spawning workers for a phase, the Orchestrator posts the lane plan (lanes, owned directories, acceptance criteria, agent per lane) and waits for the owner's approval.
- Each worker ends with a structured report: DONE (tests passing, ADRs written, device checklist attached) or BLOCKED (what is needed). The Orchestrator verifies the tests pass, but **the owner merges**, one branch/PR per lane, after running the device checklist.
- Superset's own docs recommend orchestration for mechanical fan-out with clear acceptance criteria that tests can verify. Anything that can only be verified on a device is not fully verifiable by the Orchestrator; treat it as needing owner review.

---

## 1. Owner and working norms

Starling is an open-source project in the owner's bird-named "Nest" family (Pigeon, Crow, etc.).

Norms:

- No sycophancy. Push back when something is wrong, including this brief.
- No em dashes in any prose you write (docs, READMEs, commit messages, UI copy).
- Research with primary sources (Apple docs, specs, source code) and cite them in design docs.
- A working demo that real people use beats protocol completeness. Optimize for "5 real friends use it," not feature count.

---

## 2. Product

### 2.1 What Starling is

An open-source, local-first agent-to-agent system for iPhone. Each person's phone runs an on-device AI agent that knows their availability, intent, and preferences. When two people want to coordinate, their agents negotiate directly and share only what their owners allow. The name comes from starling murmurations: coordination that emerges from neighbors, with no leader.

Two deliverables in one repo, Apache-2.0:

- **StarlingKit**: Swift packages (protocol, transport, policy and consent layer, negotiation building blocks). The open-source contribution other developers can use.
- **Starling app**: the reference iOS client, shipped via TestFlight.

Apache-2.0 because it matches A2A and includes a patent grant. Avoid GPL: it is widely considered incompatible with App Store distribution.

### 2.2 Core model: "Pair in person, coordinate anywhere"

- Being in the same place is the trust bootstrap. Pairing = adding a friend. No accounts, no phone numbers, no server-side identity.
- Keys exchanged at pairing secure all later sessions over any transport.
- Co-located negotiation is the headline only for group moments (friends at a table) and, later, events with no signal.

### 2.3 Audiences

- Students and friend groups who do not use calendars much: rely on stated intent.
- Adults and families who do use calendars (example: a parent): rely on calendar availability.
- These must interoperate. A calendar-driven agent must be able to schedule with an agent whose owner has no calendar.

### 2.4 The LLM must earn its place

A feature qualifies only if the on-device model does real work: turning messy natural language into structured constraints, fuzzy matching ("food" matches "boba run"), or reading unstructured data. If buttons and plain logic would do the job, it is not a Starling feature.

### 2.5 User journey (v1)

1. **Setup (about 2 minutes):** install; grant Local Network permission, optional calendar access, notifications; describe rules in plain language ("no plans before 10," "never share where I am"), which the app turns into structured constraints the user can review.
2. **Pairing (in person):** both tap Pair and confirm a PIN. This is the only step that requires being together.
3. **Use (from anywhere):** make a request. The agents negotiate. A consent sheet shows exactly which fields will leave the phone. The owner approves. Both humans confirm the result.
4. **Group moment (co-located):** N friends at a table tap "next hangout" or "where should we eat" and get an answer.

### 2.6 v1 features (app)

> **Phase 1.5 (2026-09-30):** these features become **skills** on one platform: Down for…, Find a time, Pick a place, and Swap photos (flagged off). See `docs/plans/phase-1.5-prompt.md` and ADRs 0010 to 0018. Where they differ from this section, they win.

1. **Down? matching.** The owner states current intent in plain language ("free tonight, want food, under $15, not far"). Agents check paired friends' agents. Notify only on a mutual match. A "maybe" is revealed only if the other side is also interested.
   - Precedent: Down to Lunch reached #1 in Social Networking on the App Store in April 2016, then suffered from notification spam and was gone by 2018. Match-before-notify is the direct fix.
2. **Calendar scheduling (adults and families).** Availability comes from pluggable sources: EventKit free/busy; stated intent; and, when the agent has nothing, one quick question to its owner ("Mom's agent wants a time this weekend. Saturday afternoon?").
   - Precedent: Blockit (former Sequoia partner; 200+ companies) does agent-to-agent calendar negotiation, but it is cloud-based and work-focused via email and Slack. Starling's position: personal and family scheduling where the calendar never leaves the device.
3. **Group decision.** Pick a place or activity from private per-person constraints (budget, diet, preferences) that nobody has to say aloud.

Demo narrative: one night. Before (Down forms the plan), during (group decision picks the place), after (v2 photo swap). Plus a short demo of a parent and a student scheduling across the calendar/no-calendar gap.

### 2.7 Five building blocks (StarlingKit API design)

Features are thin layers over these:

1. **Private aggregation:** private constraints combine into a group answer; nobody sees others' inputs.
2. **Mutual reveal:** interest is revealed only if mutual (plain yes/no needs no model; uses PSI).
3. **Private query:** an agent answers a question from its owner's data without exposing the data.
4. **Negotiation with private limits:** each side's walk-away point stays secret. Single-issue price needs no model; the model matters for multi-issue deals.
5. **Matched exchange:** items offered only to relevant people; the owner approves each one.

### 2.8 Backlog (v2, mostly as example apps in the repo, not in the main app)

- Event photo swap (match by time and location window; approve each photo). Candidate for the main app in v2.
- Gift help (private query; the recipient opts in; their agent never reveals who asked or what).
- Mutual reveal for rooming, reconnecting, crushes. Precedent: Facebook Secret Crush (2019) required a server holding everyone's lists and notified targets of one-sided interest. Starling needs neither.
- Fair rent and chore splits with envy-free fair division (precedent: Spliddit, CMU; 60,000+ users and 13,277 rent-division instances by Feb 2016). Open problem: the computation needs all valuations in one place. Compare one-trusted-phone computation vs. secure multiparty computation and document the tradeoff.
- Selling among friends (multi-issue negotiation only).
- Study-partner matching.
- Shared party queue across music services.
- Warm intros through paired friends (one hop at a time, consent at each hop).

### 2.9 Explicitly cut

Receipt splitting (Splitwise and Venmo cover it). Any core dependency on the ledger or ecash projects. Borrow/lend (no inventory data exists). Friend-sourced recommendations (no data source people already maintain). Safety check-ins (Find My). Live translation (Apple ships it).

---

## 3. Architecture (researched defaults)

### 3.1 Platform

- **iPhone only for v1.** Apple's on-device model requires Apple Intelligence (iPhone 15 Pro or later). Android is out: iOS-to-Android Wi-Fi Aware pairing has been reported unreliable.
- **Minimum iOS 27, Swift 6 strict concurrency.** Every Apple Intelligence iPhone (iPhone 15 Pro and later) runs iOS 27, so requiring it excludes no one who could run the model anyway, and it unlocks the iOS 27 Foundation Models APIs. Verify this reasoning before locking it in.
- In iOS 27, not all Apple Intelligence iPhones get the strongest on-device model. Negotiation schemas must work on the weaker one.
- Wi-Fi Aware is available to iOS/iPadOS apps only (not macOS), and not in the Simulator.

### 3.2 Layers

```
App (SwiftUI)
  Features: Down, Scheduling, GroupDecision
StarlingKit
  Negotiation     building blocks (aggregation, mutual reveal, query, bargaining, exchange)
  Agent           on-device model wrapper, @Generable schemas, token budgeting
  Policy          deterministic egress rules + consent sheet data
  Availability    pluggable sources: EventKit, stated intent, ask-owner
  Identity        device identity keys, paired-peer store, key exchange at pairing
  Protocol        typed messages; A2A mapping (Phase 3)
  Transport       protocol + implementations: Loopback, LocalP2P, WiFiAware, Relay
  PSI             interface only; implementation comes from Nightjar (separate project)
```

### 3.3 Transport

- **Do not use Multipeer Connectivity.** It is deprecated in the iOS 27 SDK ("Use Network Framework instead") and has reported regressions on iOS 26.
  - Migration: https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
  - Sample: https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol
  - Reference library (open-source MPC replacement: QUIC over Network.framework, AWDL-capable): https://github.com/security-union/Stormo
- **LocalP2P:** Network framework peer-to-peer (Bonjour + AWDL) for ad hoc co-located sessions, including group moments.
- **WiFiAware:** for paired friends. Pairing is mandatory, uses a PIN via DeviceDiscoveryUI, and persists (visible in Settings > Privacy & Security > Paired Devices). Requires the `com.apple.developer.wifi-aware` entitlement and `WiFiAwareServices` declarations.
  - https://developer.apple.com/documentation/wifiaware
  - Pairing required: https://developer.apple.com/forums/thread/791628
- **BLE:** presence hints only. In the background the local name is not advertised and service UUIDs move to the overflow area.
  - https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)
- **Loopback:** in-memory transport for tests and simulation. Build this first.

### 3.4 Remote coordination: the hard part (research task, Phase 2)

"Coordinate anywhere" cannot be fully serverless on iOS:

- A backgrounded iOS app cannot keep listening sockets open, so a friend's phone is usually unreachable.
- Waking it requires APNs, and sending APNs pushes requires a server.
- Foundation Models requests in the background may be throttled or canceled, so the woken agent may not be able to negotiate until its owner opens the app.
  - https://developer.apple.com/forums/thread/833642

Default design, to be validated:

- A **blind relay**: store-and-forward of end-to-end encrypted blobs addressed by opaque peer IDs, plus APNs wake-ups. The relay sees no content, no names, and no social graph beyond opaque IDs.
- Negotiations are **asynchronous**. UX example: "Maya's agent will reply when she next opens her phone." Down matching must degrade gracefully (for example, matches computed when either party opens the app).
- Candidates for the relay: iroh (1.0 released; QUIC with BLAKE3; research whether usable Swift bindings exist: https://iroh.computer/blog/the-road-to-iroh-1-0) or the existing Rust relay from the owner's Pigeon project.

### 3.5 Identity and security

- Each device generates identity keys with CryptoKit and stores them in the Keychain. Exchange and pin keys over the first paired connection. Later sessions on any transport are authenticated and end-to-end encrypted with those keys.
- Choose between a Noise handshake (Bitchat uses Noise with Curve25519) and QUIC/TLS with pinned raw keys. Document the choice.
- **Treat everything a peer sends as untrusted input to the model (prompt injection).** Messages are typed schemas (offer, counteroffer, accept, reject, query, answer), generated with `@Generable`, never free text passed straight to the model.
- A **deterministic policy layer**, not the model, decides what data may leave the device.
- Publish a threat model before claiming any privacy property. (Bitchat was criticized for making security claims before any external review.)

### 3.6 Model

- Default: `SystemLanguageModel`. The context window is 4096 tokens, shared between input and output. Use the token-counting APIs (`contextSize`, `tokenCount(for:)`, iOS 26.4+).
  - https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- iOS 27 opens Foundation Models to other providers behind the same session API (PCC, Core AI, MLX; Anthropic and Google integrations announced).
  - https://developer.apple.com/videos/play/wwdc2026/339/
  - https://developer.apple.com/videos/play/wwdc2026/241/ (dynamic profiles, Evaluations framework, Vision tools)
- PCC models are free for apps in the Small Business Program with fewer than 2M downloads: https://developer.apple.com/wwdc26/guides/ios/
- Use the Evaluations framework to measure negotiation quality as prompts change.

### 3.7 Privacy, consent, App Review

- App Review guideline 5.1.2(i) (Nov 2025): apps must clearly disclose, and get explicit permission, before sharing personal data with third parties, including third-party AI. https://developer.apple.com/app-store/review/guidelines/
- A peer whose agent runs a cloud model is arguably third-party AI. Therefore:
  - Each agent card declares where its model runs (on-device, PCC, or a named cloud provider).
  - Users can set a policy such as "only negotiate with on-device agents."
  - A per-exchange consent sheet shows exactly which fields will leave the phone.
- Open question: can model locality be verified (App Attest?) or only self-declared? Be honest in the UI about which.

### 3.8 Protocol: A2A (Phase 3)

- A2A v1.0 is stable, governed by the Linux Foundation, and supports extensions and custom bindings. https://a2a-protocol.org/latest/ and https://github.com/a2aproject/A2A
- There is no official Swift SDK; see the open proposal: https://github.com/a2aproject/A2A/discussions/1931
- The community SDK arkavo-ai/a2a-swift has pluggable transport and a conformance harness (arkavo-ai/a2a-conformance): https://github.com/arkavo-ai/a2a-swift
- Open question: A2A assumes client/server roles over HTTP and may map poorly onto symmetric, intermittent local links. Acceptable alternative: a native lightweight protocol plus an A2A bridge. Decide with evidence.

### 3.9 PSI (Nightjar, separate project)

- Define a `PSIProvider` protocol in StarlingCore and ship a clearly labeled **insecure stub** for development.
- Known risk: small input domains. A week of 30-minute slots is about 336 items, so a dishonest peer can submit every slot and learn your full availability. Required mitigations: reject oversized sets (set sizes are visible in DH-based PSI), plus a cardinality-only mode.
- Reference implementation: https://github.com/OpenMined/PSI (C++ with Rust/Go/JS/Python bindings; no Swift).

---

## 4. Repo layout and engineering conventions

```
starling/
  docs/BRIEF.md             (this file)
  docs/ARCHITECTURE.md      (Orchestrator-owned)
  docs/THREAT_MODEL.md
  docs/decisions/           (one short ADR per major decision, with sources)
  Packages/
    StarlingCore/           (protocols, message types, IDs; Orchestrator-owned)
    StarlingTransport/
    StarlingIdentity/
    StarlingAgent/
    StarlingPolicy/
    StarlingAvailability/
    StarlingNegotiation/
    StarlingProtocolA2A/    (Phase 3)
  App/                      (SwiftUI app target)
  Examples/                 (v2 example apps)
  Relay/                    (Phase 2, if a relay is built here)
  Tools/Simulator/          (N-agent simulation over Loopback)
```

Conventions:

- **Avoid .pbxproj merge conflicts:** keep almost all code in SwiftPM packages and generate the app project with XcodeGen or Tuist (the Orchestrator picks one in Phase 0). Do not commit hand-edited project files from multiple lanes.
- Swift 6 language mode, strict concurrency, no warnings in CI.
- Every package has unit tests runnable with `swift test` on macOS where possible.
- Anything model-dependent sits behind a protocol with a deterministic fake for tests.
- CI: GitHub Actions on macOS. Verify that runner images with the needed Xcode version are available; if not, document the local test command instead.
- Commit messages and docs follow the no-em-dash rule.

---

## 5. Phases

Each phase has exit criteria. Do not start a phase until the previous one's exit criteria are met or explicitly waived by the owner.

### Phase 0: Foundations and spike

Goal: prove the core loop on real hardware and measure the model budget.

- Verify Sections 3.1 to 3.6 against current docs; record any contradictions as ADRs.
- Scaffold the repo, packages, and project generation; CI green.
- Freeze v0 interfaces in StarlingCore: `Transport`, `PeerID`, `Message` (typed envelope), `AgentModel`, `PolicyEngine`, `AvailabilitySource`, `PSIProvider`.
- Loopback transport plus N-agent simulator.
- LocalP2P transport on Network framework.
- Model spike: `@Generable` offer/counteroffer schemas; harness measuring tokens and latency per negotiation round on device.

Exit: two iPhones exchange typed messages over LocalP2P; a report states tokens and latency per round and whether 4096 tokens fits realistic negotiations.

### Phase 1: Down? (local)

- Identity: key generation, pairing flow (Wi-Fi Aware + DeviceDiscoveryUI), key exchange and pinning, paired-peer store.
- Negotiation: intent parsing (natural language to structured constraints), matching, mutual-reveal logic (using the PSI stub), match-before-notify.
- Policy: egress rules and consent sheet model.
- App: onboarding, rules editor, pairing screen, Down screen, consent sheet, local notifications.
- Adversarial tests in the simulator: prompt-injection payloads from a malicious peer, oversized PSI sets, replayed messages.

Exit: two paired iPhones get a notification only on a mutual match; no data leaves a device without passing through the policy layer; adversarial tests pass.

### Phase 1.5: From a Down app to an agent interaction platform

Skills, one lifecycle, chaining through artifacts, just-in-time permissions, global privacy topics, and a new Home, New, Friends, and You. Scope and exit criteria: `docs/plans/phase-1.5-prompt.md`; decisions: ADRs 0010 to 0018.

### Phase 2: Scheduling, group decision, remote

- Availability sources: EventKit free/busy (full calendar access required to read), stated intent, ask-owner fallback. Calendar and non-calendar agents must interoperate.
- Group decision: N-party private aggregation over LocalP2P.
- Remote: research and implement the blind relay + APNs design in Section 3.4, or propose a better one. Asynchronous negotiation UX.

Exit: parent/student scheduling demo works remotely across the calendar/no-calendar gap; 4+ phones complete a group decision at a table.

### Phase 3: Protocol and open-source readiness

- A2A binding (or a justified alternative) with a local transport; run the conformance harness.
- THREAT_MODEL.md, README with demo video, contributor docs.
- TestFlight build; 5.1.2(i) consent flows reviewed.
- First milestone with users: 5 friends fully paired with each other and actually using it.

### Phase 4: v2

- Event photo swap.
- Example apps from Section 2.8.
- Research: letting iPhones without Apple Intelligence participate via PCC or a consented cloud model, and what that costs in privacy and consent UX.

---

## 6. Agent lanes

Suggested lanes. Any lane can run on Claude Code or Codex; keep the Orchestrator on the same agent throughout for continuity. Each lane: owns its directories, reads BRIEF.md and ARCHITECTURE.md first, writes an ADR for any decision not already covered, and ends with a device test checklist.

### Phase 0 (run the Orchestrator lane first, then B to D in parallel)

- **A. Orchestrator:** research verification, ADRs, repo scaffold, project generation, StarlingCore interfaces, CI. Owns `docs/`, `Packages/StarlingCore/`, root config.
- **B. Transport:** Loopback + LocalP2P + simulator. Owns `Packages/StarlingTransport/`, `Tools/Simulator/`.
- **C. Model spike:** schemas, token/latency harness, Evaluations setup. Owns `Packages/StarlingAgent/`.
- **D. App shell:** SwiftUI skeleton, navigation, placeholder screens bound to fakes. Owns `App/`.

### Phase 1 (after the Orchestrator freezes v1 interfaces)

- **E. Identity and pairing:** Owns `Packages/StarlingIdentity/`, plus the WiFiAware transport in `Packages/StarlingTransport/WiFiAware/` (coordinate with B's owner via the Orchestrator).
- **F. Negotiation:** intent parsing, matching, mutual reveal. Owns `Packages/StarlingNegotiation/`.
- **G. Policy and consent:** Owns `Packages/StarlingPolicy/`.
- **H. App features:** onboarding, rules editor, Down UI, consent sheet. Owns `App/`.
- **I. Red team:** adversarial simulator scenarios and fuzzing of message decoding. Owns `Tools/Simulator/Scenarios/` and test targets only; files issues rather than editing other lanes' code.

### Phase 2

- **J. Availability:** Owns `Packages/StarlingAvailability/`.
- **K. Group decision:** N-party aggregation in `Packages/StarlingNegotiation/Group/`.
- **L. Remote:** relay research, ADR, implementation. Owns `Relay/` and `Packages/StarlingTransport/Relay/`. Research first, code second.

### Phase 3

- **M. A2A binding:** Owns `Packages/StarlingProtocolA2A/`.
- **N. Docs and release:** README, threat model review, TestFlight prep.

### Kickoff prompt template for a lane

```
You are the [LANE NAME] agent for Starling. Read docs/BRIEF.md and docs/ARCHITECTURE.md fully before doing anything.
You own: [DIRECTORIES]. Do not edit files outside them; if you need an interface change, stop and write the request in docs/requests/[lane].md for the Orchestrator.
Goal for this phase: [GOAL FROM SECTION 5].
Before coding, verify the relevant sources in the brief are still current and note any contradictions.
Deliver: code with tests runnable without a device, an ADR for any new decision, and a device test checklist for the owner.
Follow the owner's norms: no sycophancy, no em dashes in prose, cite primary sources.
```

---

## 7. Testing without devices

- The Simulator cannot run Wi-Fi Aware. Verify whether Foundation Models works in the Simulator on the current Xcode and host Mac; do not assume it does.
- Therefore, every lane must work against:
  - the Loopback transport,
  - a deterministic fake `AgentModel` (scripted responses) for logic tests,
  - the N-agent simulator for multi-party and adversarial scenarios.
- Real-device testing is done by the owner using each lane's checklist. Keep checklists short, numbered, and specific ("Phone A: tap Pair. Expect: PIN sheet within 2 seconds.").

---

## 8. Open questions (research before or during the relevant phase)

1. Does A2A map cleanly onto symmetric, intermittent local links, or is a native protocol plus bridge better? (Phase 3)
2. Remote design: relay choice (iroh vs. Pigeon's Rust relay vs. other), APNs usage, what the relay can learn, async UX. (Phase 2)
3. Is Wi-Fi Aware PIN pairing too much friction? Would a QR or tap-based key exchange over Network framework be a better trust bootstrap? (Phase 1)
4. Can a peer's model locality be verified, or only self-declared? (Phase 1)
5. Does 4096 tokens suffice for multi-round, multi-party negotiation, and how does the weaker iOS 27 on-device model perform? (Phase 0)
6. Can iPhones without Apple Intelligence participate via PCC or a consented cloud model? (Phase 4)
7. Prior art: find existing local or on-device agent-to-agent systems on phones and local A2A bindings, and state how Starling differs. (Phase 0)
8. Name collisions: an ETHGlobal hackathon project named "Starling" (P2P agent swarm) and a "Starling Agent" VS Code extension exist. Choose a repo name that avoids confusion (for example `starling-ios`). (Phase 0)

---

## 9. Related projects (separate repos and chats; interfaces only here)

- **Nightjar:** private set intersection library (Rust core, Swift via UniFFI). Starling consumes it through `PSIProvider`.
- **Crow:** capability-based content-addressed storage, being repositioned on top of iroh. Possible future attachment backend.
- **Pigeon:** BLE/LoRa mesh messenger with a Rust relay. Its relay is a candidate for Starling's remote transport.
- **Weaver:** local-first group expense ledger. No core dependency from Starling.
