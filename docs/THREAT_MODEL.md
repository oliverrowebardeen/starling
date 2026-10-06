# Starling threat model

Status: **draft, secure channel section only** (lane E1, Phase 1, 2026-09-30). Other sections (policy and consent, negotiation, the relay) belong to their lanes and the Orchestrator.

**No privacy claim may be made on the strength of this document yet.** ADR 0003 care requirement 7 requires a Codex review of the cryptography first (section 6 says what such a review is). Until that review passes and is recorded here (section 6), describe Starling as "encrypted, not yet reviewed."

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
| **Unpairing and disconnecting take effect immediately, on every transport.** Once an unpair or disconnect has begun, no session with the peer authenticated before it is usable on any of the device's transports. No pin survives an unpair, including one saved by a pairing ceremony that was already running or rewritten by a rename. A commit that a revocation overtakes leaves no pin, and no session authenticated while it was in flight stays usable. | One identity-scoped `PinAuthority`, shared by every transport and pairing service, holds the revocation state behind a mutex with no suspension points. Every session is stamped with the epoch it was authenticated under. Every frame is checked against the peer's current epoch in the same mutex section that seals it, or that commits and publishes it. The epoch moves on every revocation, at the end of every unpair, and on every commit rollback (ADR 0100 decision 11, with an audit of every read of revocation state). | `unpairWinsAtEveryAwait` (every await on both paths), `RenameTests` (a rename cannot outlive an unpair), `SharedAuthorityTests` (two transports sharing one authority, including a disconnect during a held commit), `unpairingDuringAnInitiatorPinLookupStopsTheHandshake`, `unpairingDuringAResponderPinLookupStopsTheHandshake`, `unpairingAfterConfirmingARepairWins`, `unpairingDuringAPendingSaveWins` |
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
2. **Availability.** A network attacker or an OS-paired device can drop frames, displace links (ADR 0110), and replay old handshake messages to use up pending-session slots. Every one of these is denial of service, not impersonation. Losing a session confirmation is recovered by acknowledged retries. The last confirmed session stays usable for receiving until a newer one is confirmed, however many unconfirmed attempts come in between (ADR 0100 decision 5). A link that loses every confirmation and acknowledgement ends in silence after a bounded number of handshakes, whatever triggered them (confirm timeout, nonce cap, or reconnect). Every session that bounded sequence creates is kept for receiving, one the peer is heard on counts as confirmed, and no new attempt (not even an explicit reconnect) may start while its retirement could evict one of them. Memory is bounded too: unauthenticated link claims leave no per-peer state, and per-peer generations and replay caches are capped (ADR 0100 decision 12).
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

## 5a. What Phase 1.5's skills and pairing do not protect

These come from the lanes' requests (`docs/requests/P15-*.md`) and the Phase 1.5 reviews.

1. **The organizer of a group step is trusted.** Friends in a plan are often not paired with each other, so a phone cannot check another friend's yes or no. Whoever organizes a step reports the outcome:
   - Down for… and Pick a place: the organizer's final roster and place (ADR 0233 decision 13).
   - Change the plan: the suggester reports that everyone agreed (ADR 0243). The suggester who added a friend can also tell that friend's phone, and only that phone, that another member left, because the forwarded departure carries nothing the friend can verify.
   - A dishonest paired friend can therefore show different plans to different friends. Honest phones never diverge: a change names the revision it changes, and a phone takes part in one change per plan at a time (ADR 0023). The defense against a liar is that every friend was paired in person.
2. **Pairing codes.** A phone in the middle of two victims learns each victim's code from that victim's message 3. Once a phone has sent its nonce, a request to start over ends the ceremony visibly, so each further guess shows a failure. A sheet rejoins on its own at most once, after the failure has been on screen for 3 seconds, so one Add friend tap gives a middle phone at most two nonces (about 2 in 10^6), within ADR 0101's bound (ADR 0260).
3. **A third phone in range can restart or end a pairing** before this phone's nonce goes out, with IDs it overheard, and end one visibly after. It learns no code. Pairing requests are unauthenticated claims; a forged one can only start a ceremony whose code will not match. A finished ceremony replays its last encrypted messages up to 3 times, which reveals nothing new. All of this is denial of service.
4. **Wi-Fi Aware roles.** A forged link hello from an OS-paired device can make a phone settle a role that stops the link until the next genuine hello: denial of service, and only from devices the owner paired in person (ADRs 0110, 0260).
5. **Find a time.**
   - A starter shows each friend up to 16 of its free times; with a calendar, the gaps show busy time in the range, never why. A friend who keeps sending requests learns 16 answers per request, at most 4 open requests at a time. Private set intersection would remove this (ADR 0221).
   - Every no while answering is silence, and every no after the owner's tap is the same `reject(noOverlap)`. A yes from a calendar still comes faster than one from an owner (ADRs 0019, 0221).
   - Each conversation can ask about at most 16 times, and an ended conversation is retired for good (ADR 0021). A dishonest friend can still open new conversations, at most 4 at a time.
   - Calendar details are Never by default and are still read on the phone to judge candidates; only yes or no to the starter's own times leaves (ADR 0019).
   - Checkpoints hold candidate times, friends' answers, and peer IDs at rest, with complete file protection, until the interaction ends (ADR 0222).
6. **Pick a place.**
   - The organizer learns each friend's acceptable subset of its own candidates, in order. That is the aggregation's disclosure, shown on the friend's consent sheet first.
   - Apple Maps receives the owner's typed area, or a region around the owner for Nearby; on friends' phones, the identifiers of the venues they are asked about.
   - Silence hides "nothing fits" from the organizer, at the cost of waiting for the answer window.
   - Hard limits are enforced only on known facts. Apple Maps supplies categories but no price or diet data, so on device most budget and diet limits are unchecked (ADR 0230).

## 6. Review history

Every "Codex review" here is an automated adversarial code review by an AI model (OpenAI's Codex coding agent), run against a pull request. None of these is an independent security audit, and no independent audit of Starling has taken place.

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

The fourth Codex review (2026-09-30, at 0e98306) found three more, and asked for the revocation state to be redesigned without awaits because each round had found a race at a new await:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| 1 (high) | A revocation race: a `disconnect` during a held commit let the peer authenticate with the just-saved pin, and the commit's rollback removed the pin but left the session | "Unpairing takes effect immediately" (the session survived a rolled-back pin) | Redesign: sessions stamped with an epoch and checked on every frame; the epoch moves on every revocation and rollback; lookups refused while a commit is in flight (ADR 0100 decision 11) |
| 2 (high) | Scope of authority: each transport had its own authority, so an unpair through one transport missed the other's session and lock | "Unpairing takes effect immediately" across transports | One identity-scoped authority created by the app and injected into every transport and pairing service |
| 3 (medium) | Session retention: a reconnect with no current session skipped the restart budget and evicted a session the peer still used | Availability only | One admission gate for every new handshake (ADR 0100 decision 5) |

The fifth Codex review (2026-10-01, at b6f2fac) found that the redesign held, and three gaps between separate lock sections or after an await:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| 1 (high) | A commit's decision and its end were two mutex sections; a revocation in between left the pin | Property (d) of ADR 0100 decision 11 | One section decides and ends the commit |
| 2 (high) | A frame checked against the epoch, then delivered (or sealed) after another transport's revocation | "Unpairing and disconnecting take effect immediately, on every transport" | The final check, state commit, and publishing (or nonce and sealing) are one section under the authority |
| 3 (medium) | Reconnects admitted before an await installed sessions without rechecking, evicting one the peer used | Availability only | Admission after the lookup, immediately before install; concurrent attempts coalesce |

ADR 0100 decision 11 now lists every read of revocation state and the section that covers its action.

The sixth Codex review (2026-10-01, at 1ca5ca3) found no high findings and confirmed the audit table. It found one medium, tracked as issue #32 and fixed in a follow-up PR:

| Finding | Class | Guarantee affected | Fix |
|---------|-------|--------------------|-----|
| #32 (medium) | Unpair stalling on the network: unpair awaited revocation observers before deleting the pin, and one observer's work includes the ceremony's cancel notice, a network send. A stalled send kept the pin stored indefinitely, and a restart while hung reloaded it. | "No pin survives an unpair" held only once the unpair finished, and a stalled link could keep it from finishing. Sessions were already dead (epoch). | Observers are notified after the delete and never awaited; an unpair awaits only Keychain I/O (ADR 0100 decision 11) |
| #40 (medium, focused review of the #32 fix) | Unbounded deferred work: with a stalled revocation observer, every revocation added another suspended notification task | Availability only (memory and tasks) | Notices coalesce per observer and peer, keeping the latest epoch; a stalled observer holds one task (ADR 0100 decision 11) |

## 7. Assumptions

- CryptoKit's X25519, ChaChaPoly, SHA-256, HMAC, and system random number generator are correct.
- The Keychain enforces its accessibility classes.
- The Noise implementation matches the spec. Two independent vector files pass, and the first Codex review found no conformance issues; a review of the state-machine fixes is pending.
- Transports report peers by key-derived `PeerID` (ADR 0100 decision 8).
- Both owners of a pairing are physically together and look at both screens.

## 8. Open items

| Item | Owner |
|------|-------|
| Codex review of the issue #32 follow-up (ADR 0003 care requirement 7) | Orchestrator |
| Wi-Fi Aware pairing binding with `deriveSharedSecret` and XXpsk3 (ADR 0102) | Owner decision, then E1 and E2 |
| Padding to hide message sizes, before the relay | Phase 2 |
| Rotating link-visible `PeerID`s, or hiding them in hellos | Phase 2 or later |
| Detecting one-sided pairing | E1 follow-up |
| Simulator `impersonation` scenario: switch it to run over `SecureTransport` and remove the known-issue marker | Lane I |
