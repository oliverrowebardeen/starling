# Starling threat model

Status: **draft, secure channel section only** (lane E1, Phase 1, 2026-09-30). Other sections (policy and consent, negotiation, the relay) belong to their lanes and the Orchestrator.

**No privacy claim may be made on the strength of this document yet.** ADR 0003 care requirement 7 requires a Codex review of the cryptography first. Until that review passes and is recorded here (section 6), describe Starling as "encrypted, not yet reviewed."

## 1. Scope

This section covers `Packages/StarlingIdentity`:

- device identity keys and their storage;
- pinned friends (`PairedPeerStore`);
- in-person pairing (`PairingService`, ADR 0101);
- the secure channel (`SecureTransport`, ADRs 0003 and 0100) that sits between `Outbox`/`Inbox` and every transport.

Design references: ADR 0003 (why message-layer Noise), ADR 0100 (secure channel details), ADR 0101 (pairing ceremony), ADR 0102 (bootstrap).

## 2. Assets

1. The device's X25519 static private key. Whoever holds it is this person to every friend.
2. The pinned-friends list: who this person is friends with, and which key each friend is.
3. Message contents: availability, intents, budgets, keywords, accept and reject decisions.
4. Metadata: that two devices talk, when, how often, and how much.

## 3. Attacker model

| Attacker | Capabilities assumed | In scope |
|----------|----------------------|----------|
| **Network attacker near the phones** | Sees, drops, delays, reorders, replays, and injects frames on any link. Claims any `PeerID` on an unauthenticated link, including by taking over a friend's link address. Knows every public key, which is not secret. | Yes |
| **OS-paired device that is not a Starling friend** | An owner once typed its Wi-Fi Aware PIN, so it can open links. It can claim a paired friend's `PeerID` in the link hello and displace that friend's link (lane E2, ADR 0110). | Yes |
| **Malicious paired friend** | Holds a valid pinned key. Sends any well-formed or malformed traffic under its own identity. | Yes, for authentication. Content-level abuse (prompt injection, oversized PSI sets) belongs to other lanes. |
| **Attacker in the room during pairing** | Runs a man-in-the-middle between two phones that are pairing, including grinding keys to make codes collide. | Yes |
| **Thief of a device's static private key** | Has the key; does not control that device. | Partly (section 5) |
| **Attacker with code execution on an unlocked phone, a jailbreak, or a compromised OS** | Everything. | No |
| **Global passive observer** (ISP, relay operator) | No relay exists in Phase 1. | Phase 2 |

## 4. What the secure channel protects

| Property | Mechanism | Evidence |
|----------|-----------|----------|
| **Only paired friends are heard.** A frame reaches `Inbox` only if it decrypts under a live KK session with a key pinned at pairing. Unknown keys, forged link identities, tampered, truncated, replayed, and reordered frames are dropped without a reply. | Noise KK (ADR 0100). Strictly increasing explicit nonces. | `SecureTransportTests`, `ImpersonationTests` |
| **The sender is who the link claims.** `peerAvailable` and `received` carry the key-derived `PeerID` of the key the peer proved. `Inbox` then rejects an envelope whose `sender` differs from it. | The `PeerID` is SHA-256 of the static key. Each session is checked to prove a key that hashes to the claimed ID before it is installed. | `forgedSenderAndForgedLinkIdentityAreRejected`, `aPairedPeerCannotSpeakForAnother` |
| **Unpairing takes effect immediately.** Once `SecureTransport.unpair` has begun, the peer has no session. No pin for it survives the unpair, including one saved by a pairing ceremony that was already running. No handshake lookup that overlaps the unpair returns the pin. | One `PinAuthority` orders every pin mutation and use. The revocation mark is taken before the first await; commits and removals share one lock; lookups are refused while a removal is in progress; commits leave no pin if a revocation starts before they end (ADR 0100 decision 11). | `unpairWinsAtEveryAwait` (every await on both paths), `unpairingDuringAnInitiatorPinLookupStopsTheHandshake`, `unpairingDuringAResponderPinLookupStopsTheHandshake`, `unpairingAfterConfirmingARepairWins`, `unpairingDuringAPendingSaveWins` |
| **Link displacement does not become impersonation.** A link that claims a friend's ID but cannot prove the key never gets a session, and never displaces or shadows the friend's live one. | Sessions are installed only by a completed handshake or a successful decryption. `status(of:)` shows the claimed ID next to the proven key. | `aDisplacingLinkDoesNotShadowTheAuthenticatedSession`, `anImpostorLinkAfterLinkLossIsNeverAnnounced` |
| **Confidentiality and integrity of content** against the network attacker. | ChaChaPoly under per-session keys. | `framesAreEncryptedOnTheWire`, the vector tests |
| **Forward secrecy.** Stealing static keys later does not reveal past sessions. | Ephemeral keys per session. Noise section 7.7 rates KK transport payloads "2, 5". The responder's payloads get those properties because it sends nothing until the initiator's first frame arrives. | ADR 0100 decision 5 |
| **Resistance to key-compromise impersonation.** With Bob's stolen key, an attacker can forge KK message 1 "from Alice", but can never make Bob announce Alice or accept her traffic. | The responder waits for a frame that decrypts under the new session. | `aStolenResponderKeyCannotImpersonateTheInitiator` |
| **Nonces never repeat or wrap.** | Sessions roll over at 2^20 messages per direction. The Noise-reserved nonce is refused. | `sessionsRollOverBeforeTheNonceCap`, `nonceExhaustionIsAnError` |
| **Pairing resists a man in the middle** with probability 1 - 10^-6 per ceremony, provided both owners really compare the codes. | XX plus a committed nonce exchange, so no party can grind the 6-digit code (ADR 0101). | `aResponderThatBreaksItsCommitmentIsRejected`, `aManInTheMiddleShowsDifferentCodes` |
| **Nothing is pinned without both owners' consent.** A mismatch, cancel, timeout, or link loss stores nothing on that side, even if the peer's accept arrives while the cancel or timeout notice is still being sent. | Both confirmations are the commit point; every local ending is final before it notifies the peer (ADR 0101 decision 2). | `PairingTests`, including `anAcceptArrivingDuringACancelDoesNotPin` and `anAcceptArrivingDuringATimeoutDoesNotPin` |
| **Keys at rest.** The private key and the friends list are Keychain items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable: not in backups, not moved to a new phone, unreadable before first unlock. The private key type is not `Codable` and prints only its public ID. | ADR 0003 care requirement 5. | `IdentityKeyTests`, `PairedPeerStoreTests` |

## 5. What it does not protect

1. **Metadata.**
   - Link-layer identifiers, the fact that two phones talk, timing, frequency, and message sizes are all visible to a nearby observer.
   - There is no padding (Noise section 13 recommends it).
   - `PeerID`s are stable and sent in the clear in link hellos, so a device can be tracked across sessions by anyone who hears its hello. On Wi-Fi Aware this is limited to OS-paired devices; on LocalP2P, to anyone on the local network.
2. **Availability.** A network attacker or an OS-paired device can drop frames, displace links (ADR 0110), and replay old handshake messages to use up pending-session slots. Every one of these is denial of service, not impersonation. Losing a session confirmation is recovered by acknowledged retries. The last confirmed session stays usable for receiving until a newer one is confirmed, however many unconfirmed attempts come in between (ADR 0100 decision 5). A link that loses every confirmation and acknowledgement ends in silence after a bounded number of handshakes, whatever triggered them (confirm timeout, nonce cap, or reconnect). Every session that bounded sequence creates is kept for receiving, and one the peer is heard on counts as confirmed. Memory is bounded too: unauthenticated link claims leave no per-peer state, and per-peer generations and replay caches are capped (ADR 0100 decision 12).
3. **A stolen static key.**
   - A thief of Alice's key can impersonate Alice to her friends.
   - A thief of Bob's key can read nothing already sent (forward secrecy), but can pose as Bob to Bob's friends.
   - There is no key rotation or revocation. Recovery is to reset the identity and pair every friend again.
   - Keys are not in the Secure Enclave, because CryptoKit's `SecureEnclave` offers only P-256, ML-KEM, and ML-DSA keys, not X25519 (https://developer.apple.com/documentation/cryptokit/secureenclave). Keys in memory are not zeroized.
4. **Pairing when owners do not compare.** Compare-and-confirm has measured failure rates of up to 20% in user studies (ADR 0102). An owner who taps "match" without looking gives an attacker in the room the pairing. ADR 0102 proposes binding pairing to the Wi-Fi Aware PIN to remove this step.
5. **One-sided pairing** (ADR 0101). If the last confirmation is lost, one phone pins the friend and the other does not. The pinned side's handshakes then fail silently.
6. **Model locality is self-declared.** An `AgentCard` says where the peer's model runs (on-device, PCC, or a named cloud). The secure channel authenticates which device is talking, not what software or model runs on it. A modified app can lie. Brief open question 4 (App Attest) is unanswered. The UI must say "declared", not "verified".
7. **The PSI stub is not private.** `InsecurePSIStub` reveals the initiator's set to the responder. The secure channel hides it from the network, not from the peer. Until a real `PSIProvider` (Nightjar) exists, mutual reveal leaks one side's candidate slots to the other, and policy requires consent for it (ARCHITECTURE section 7).
8. **Content from a paired friend is still untrusted input.** Authentication says who sent a message, not that it is benign. Prompt-injection defenses are structural (typed values only; the model never decides egress) and belong to the Agent, Negotiation, and Policy lanes.
9. **Replays across app restarts at the `Inbox` layer.** `Inbox` replay state is in memory, but each secure session has fresh keys and nonces, so a frame captured in an old session cannot decrypt in a new one. Replay protection below `Inbox` therefore survives restarts.
10. **Anything after decryption on the device**: other apps, the OS, backups of app data outside the Keychain, notifications on the lock screen. Those are covered by other sections.
11. **The Phase 2 relay.** Store-and-forward needs its own design: a one-way pattern or HPKE, plus replay rules (ADR 0003 decision 3).

## 6. Review history

The first Codex adversarial review of PR #16 (2026-09-30) found no Noise conformance or vector issues. It reproduced three state-machine defects, fixed on the same branch, each with a regression test that reproduced it first:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| HIGH 1 | A revocation race: a pin lookup suspended across an unpair could still start or answer a handshake, and the removed peer was heard again | "Only paired friends are heard" did not hold during an unpair | Per-peer generations (ADR 0100 decision 11) |
| HIGH 2 | A cancellation race: a cancel or timeout still sending its notice could be overtaken by the peer's accept, and the pairing committed | "Nothing is pinned without both owners' consent" did not hold for cancel and timeout | Local endings are final before notifying (ADR 0101 decision 2) |
| MEDIUM 3 | A lost session confirmation: the two sides were left on incompatible sessions and nobody retried | Availability only; no confidentiality or authentication impact | Acknowledged confirmations with bounded retries; the old session is kept for receiving until then (ADR 0100 decisions 5 and 7) |

The second Codex review (2026-09-30, at b78415c) found three more state-machine defects in the same family. Each was fixed with a regression test that reproduced the reported sequence first:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| 1 (high) | A revocation race, pairing side: unpairing did not reach a re-pair ceremony already running, so the peer's accept re-pinned the removed peer and restored its session | "Unpairing takes effect immediately" did not hold for running ceremonies | `unpair(_:)` as one entry point, ceremony cancellation on revocation, commits conditional on the revocation generation (ADR 0100 decision 11) |
| 2 (medium) | Session replacement: a second unconfirmed session replaced the last confirmed one as the receive-only session while the peer still used it | Availability only | Keep the last confirmed session across unconfirmed replacements (ADR 0100 decision 5) |
| 3 (medium) | An unbounded restart loop: rollover at the nonce cap bypassed the restart budget when confirmations were lost | Availability only (handshake storm) | One restart budget for every replacement of an unconfirmed session (ADR 0100 decision 5) |

The third Codex review (2026-09-30, at 8ca174a) found three more:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| 1 (high) | A revocation race at a new await: a pairing save could land between unpair's removal and its revocation mark, leaving the pin | "Unpairing takes effect immediately" did not hold | Structural: one `PinAuthority` orders every pin mutation and use. The mark is taken before the first await, and the invariant is written down in ADR 0100 decision 11 and tested at every await of both paths. |
| 2 (medium) | Session retention: exhausting the restart budget evicted a session the peer still used | Availability only | Retention sized to the whole restart sequence; a decrypt confirms a superseded session (ADR 0100 decision 5) |
| 3 (medium) | Unbounded state: unauthenticated claimed PeerIDs accumulated per-peer state and generations | Availability only (memory) | No state for unauthenticated claims; bounded generation tables whose eviction keeps stale-lookup checks sound (ADR 0100 decision 12) |

A fourth review of these fixes is pending. The warning at the top of this document stands until a review passes.

## 7. Assumptions

- CryptoKit's X25519, ChaChaPoly, SHA-256, HMAC, and system random number generator are correct.
- The Keychain enforces its accessibility classes.
- The Noise implementation matches the spec. Two independent vector files pass, and the first Codex review found no conformance issues; a review of the state-machine fixes is pending.
- Transports report peers by key-derived `PeerID` (ADR 0100 decision 8).
- Both owners of a pairing are physically together and look at both screens.

## 8. Open items

| Item | Owner |
|------|-------|
| Codex review of the third round of section 6 fixes (ADR 0003 care requirement 7) | Orchestrator |
| Wi-Fi Aware pairing binding with `deriveSharedSecret` and XXpsk3 (ADR 0102) | Owner decision, then E1 and E2 |
| Padding to hide message sizes, before the relay | Phase 2 |
| Rotating link-visible `PeerID`s, or hiding them in hellos | Phase 2 or later |
| Detecting one-sided pairing | E1 follow-up |
| Simulator `impersonation` scenario: switch it to run over `SecureTransport` and remove the known-issue marker | Lane I |
