# ADR 0143: Wi-Fi Aware in the app before the secure channel

- Status: Proposed
- Date: 2026-09-30
- Owner: H (App features)

## Context

Lane E2's transport and pairing views are merged; lane E1's secure channel is not wired yet. E2's device checklist (`docs/checklists/phase-1-E2.md`) needs the app to pair phones, show each peer's connection state, and time round trips (`docs/requests/E2.md` section 3). ARCHITECTURE section 2 puts every transport behind the secure channel and the app's single Inbox loop, and the Phase 0 Nearby screen was kept out of Release because it sent owner-shaped data with an allow-all policy.

## Decision

1. **A link-test screen under Developer, in Debug and Release.** It runs `WiFiAwareTransport(localPeer:)` with its own `Inbox`, like Nearby did, until E1 wraps transports in the secure channel. Only one transport runs at a time, because an app can publish a service once per device (ADR 0111).
2. **Round trips send `hello` only.** The agent card is the only payload; lane G's policy always allows `hello`, so the test sends no owner data and shows no consent sheet. Sends go through an `Outbox` on the app's policy, consent provider, and audit log, so they are audited. A phone answers each conversation once and never its own pings, so replies cannot loop. This is why the screen can ship in Release without the fakes Nearby needed.
3. **A stored random peer ID** stands in for the identity-key ID until E1: kept in `UserDefaults` so a relaunched phone appears once on the other phone (E2 checklist step 10), and labeled unverified on screen.
4. **Pairing views appear only where Wi-Fi Aware runs** (`WiFiAwareSupport.isSupported`), on the pairing screen and the link-test screen. OS pairing links devices; Starling's own code check (E1) still pins the friend.
5. **The generated `Config/Starling.entitlements` is committed.** XcodeGen writes it deterministically from `App/project.yml`, and committing it lets reviewers see the entitlement. It is not the Xcode project that AGENTS.md says not to commit.

## Consequences

- When E1 merges, the app's transport becomes the secure channel over Wi-Fi Aware behind the single Inbox loop, and this screen either moves onto that stack or goes away.
- A signed device build needs the Wi-Fi Aware capability enabled for the App ID first (owner action, ADR 0111).
- The stored test ID is a claim, like every transport-reported ID before the secure channel (ADR 0003).

## Sources

- `docs/requests/E2.md` section 3; ADR 0110, ADR 0111 (lane E2).
- StarlingPolicy README: hello is always allowed and carries only the agent card.
- Adopting Wi-Fi Aware ("can only publish a given service at most once per device"): https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware
