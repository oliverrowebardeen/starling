# Phase 1 lane plan: Down? (local)

- Status: **Approved by the owner on 2026-09-30.** Owner decisions: ADR 0003 (Noise) accepted with an instruction to be careful; all 7 lanes approved to run at once; spawning and merging pre-approved; the phone-to-phone part of the Phase 0 device checklist is deferred until a friend's phone is available (the one-phone-plus-Mac variant covers it meanwhile). Xcode 27 is installed. The exact kickoff prompts are in `phase-1-kickoff-prompts.md`.
- Date: 2026-09-29
- Author: Orchestrator

Phase 1 goal (brief section 5): two paired iPhones get a notification only on a mutual match; no data leaves a device without passing through the policy layer; adversarial tests pass.

## 1. Before any lane starts (blocking)

| # | Item | Who | Why |
|---|------|-----|-----|
| 1 | Run `docs/checklists/phase-0-device.md`, or explicitly waive the device part of the Phase 0 exit | Owner | The brief says not to start a phase until the previous exit criteria are met or waived |
| 2 | Merge PR #1 (frozen v0 interfaces), then PR #2 (Phase 0 spike) | Owner | Lanes branch from `main` |
| 3 | Decide ADR 0003 (message-layer Noise vs TLS) | Owner | Lane E1's whole design depends on it |
| 4 | Install Xcode 27 on this Mac | Owner | Lanes compile iOS 27 code locally instead of only in CI; Evaluations needs it |
| 5 | Enable the Wi-Fi Aware capability for `com.oliverrowebardeen.starling` in the developer portal | Owner | Needed to run lane E2's transport on devices |
| 6 | **v1 interface freeze** in `StarlingCore`, merged to `main` | Orchestrator | Lanes must not change shared interfaces (brief section 0) |

### Proposed v1 freeze (Orchestrator does this after approval, single agent)

1. **Identity types:** `IdentityPublicKey` (32-byte X25519) and `PeerID(publicKey:)` defined as SHA-256 of the key, so an ID cannot be claimed without the key (ADR 0003).
2. **Paired peers:** a `PairedPeer` record (peer ID, public key, local nickname, paired date) and a `PairedPeerStore` protocol, with an in-memory fake in `StarlingFakes`.
3. **Shared hard-limit check:** move `HardLimits` from `StarlingAgent` into Core as `ConstraintSet.violations(of:timeZone:)`. The bench showed the model breaks hard limits, so negotiation must enforce them in code, and the agent's prompt marking must use the same logic.
4. **Down message flow**, documented in `ARCHITECTURE.md` using existing message types (no new `MessageBody` cases unless lane F proves one is needed): `hello`, then `query`/`answer` over time and activity candidates, then a `psi` run for mutual reveal of "maybe", then `propose`/`accept` for the plan.

## 2. Lanes

All lanes: read `docs/BRIEF.md`, `docs/ARCHITECTURE.md`, and `AGENTS.md` first; test without devices against Loopback, `StarlingFakes`, and the simulator; end with DONE or BLOCKED plus a device checklist. The table's "agent" column is a suggestion; the brief allows Claude Code or Codex anywhere.

| Lane | Owns | Delivers | Acceptance (verifiable without a device unless noted) | Suggested agent |
|------|------|----------|-------------------------------------------------------|-----------------|
| **E1. Identity and secure channel** | `Packages/StarlingIdentity/` | Keychain-backed X25519 identity keys; `PairedPeerStore` (Keychain + fake); the secure channel as a `Transport` decorator (Noise KK for paired peers, XX plus a short authentication string for pairing, per ADR 0003); pairing key-exchange protocol | Noise spec test vectors pass; secure channel over Loopback round-trips; tampered, replayed, and unknown-key frames are dropped; the simulator's `impersonation` known issue flips to passing; ADR on PIN vs QR bootstrap (open question 3) | Claude Code (Opus): security-critical |
| **E2. Wi-Fi Aware transport** | `Packages/StarlingTransport/Sources/StarlingWiFiAware/` and its tests | `WiFiAwareTransport` (publish and subscribe the same service, hide the asymmetric roles, one link per paired device), `DeviceDiscoveryUI` pairing views exposed for the app, entitlement and `WiFiAwareServices` snippets | Pure logic (role resolution, link table) unit-tested; builds in CI; device checklist: pair two phones, exchange frames, reconnect after walking out of range | Claude Code |
| **F. Negotiation (Down?)** | `Packages/StarlingNegotiation/` | Down session state machine: intent to constraints (with an owner-review step), per-friend matching with `query`/`answer`, mutual reveal of "maybe" through `PSIProvider` (stub), match-before-notify, timeouts and idempotent retries (transport is best-effort), hard limits enforced in code before and after every model call | Simulator scenarios with N agents on Loopback and `ScriptedAgentModel`: a mutual match notifies both sides; one-sided interest notifies no one and reveals nothing; "maybe" is revealed only if mutual; partitions and lost messages do not produce false matches; zero hard-limit violations reach `Outbox` | Claude Code |
| **G. Policy and consent** | `Packages/StarlingPolicy/` | Deterministic `PolicyEngine`: owner `DisclosureRule`s, "only negotiate with on-device agents" locality rule, non-private PSI provider forces consent, disclosure computation for the consent sheet, local audit log of what left the phone | Table-driven tests over every `MessageBody` kind; a peer card declaring a cloud model is refused under the on-device rule; `never` rules block sends end to end through `Outbox` | Codex: well specified, table-driven |
| **H. App features** | `App/` | Onboarding (Local Network, notifications), rules editor (plain language to reviewed rules), pairing screen hosting E2's views, Down screen, consent sheet, local notifications. Built against fakes first, then wired to E1, E2, F, G as they merge. Removes `StarlingFakes` from release builds | CI app build green; SwiftUI previews run on fakes; device checklist covering the full Down journey on two phones | Claude Code |
| **I. Red team** | `Tools/Simulator/Scenarios/`, test targets only (files issues, does not edit other lanes' code) | Prompt-injection keyword payloads against the real model (Mac, opt-in), oversized PSI sets, replays, consent-bypass attempts, and seeded fuzzing of `EnvelopeCodec` from the golden frame | Every scenario either passes or has a filed issue with a reproduction; fuzzing runs 10,000 seeded mutations with no crash | Codex: an independent model is a better adversary |
| **C2. Agent quality** (optional, recommended) | `Packages/StarlingAgent/` | Evaluations framework suite (Xcode 27); interpretation fixes for the bench findings (sharing flags, invented activities, dropped budgets); per-issue dynamic schemas so time-only negotiations cannot answer with activities | Evaluations suite runs in CI; interpretation accuracy on a 30-utterance labeled set reported before and after | Claude Code |

C2 is optional, but interpretation is the weakest link the bench found, and Down depends on it.

## 3. Order and merging

```
v1 freeze (Orchestrator) ──► E1, E2, F, G, I, C2 in parallel ──► H wires real packages as they land
Merge order: G ─► E1 ─► F ─► E2 ─► C2 ─► H ─► I final pass
```

- F and H start on fakes, so nothing waits on E1 or E2 to begin.
- The owner merges one PR per lane after its device checklist (brief section 0). The Orchestrator verifies tests and CI before asking.
- Seven lanes is within the default guideline of fewer than 10 agents. If device testing becomes the bottleneck (likely), run E2 and H last.

## 4. Risks

1. **Owner device time** is the real bottleneck: E2, H, and the Phase 1 exit all need two phones.
2. **Wi-Fi Aware PIN pairing friction** (open question 3): E1's ADR must compare it with a QR or tap-based bootstrap over LocalP2P.
3. **Model latency on phones** is unmeasured until the Phase 0 device run; if a round is several seconds, F should minimize model calls per match.
4. **Codex availability:** the Codex MCP server failed to connect in the Orchestrator's session. Codex lanes may need the Codex CLI configured in Superset first.
