# ADR 0100: Noise secure channel implementation

- Status: Proposed
- Date: 2026-09-30 (revised after five Codex reviews of PR #16, 2026-09-30 to 10-01; see decisions 5, 7, 11, and 12)
- Owner: Lane E1 (Identity and secure channel)

## Context

ADR 0003 (accepted with an instruction to be careful) puts authentication and encryption in a `Transport` decorator that runs Noise on CryptoKit: `Noise_XX_25519_ChaChaPoly_SHA256` for pairing and `Noise_KK_25519_ChaChaPoly_SHA256` for paired peers. It leaves open whether to adopt an existing Swift Noise library, and everything Noise leaves to the application: framing, nonce handling on a lossy link, session lifetime, and who starts the handshake.

Existing Swift implementations, checked 2026-09-30:

- Bitchat (`bitchat/Noise/NoiseProtocol.swift`, Unlicense) implements XX only, is not a standalone package, and runs two XX vectors. Its README carried "This software has not received external security review" until January 2026; no external review report is public. A June 2026 commit fixed a remote crash on 16 to 19 byte ciphertexts.
- `swift-libp2p/swift-noise` (MIT, 3 stars), `samueltangz/swift-noise-protocol` (last commit 2021), `trancee/noise-protocol` (new, 0 stars), and others: none has a public review.
- snow, a widely used Rust implementation, says "This library has not received any formal audit."

Noise revision 34 facts this design relies on:

- Section 5: transport messages use `EncryptWithAd`/`DecryptWithAd` "with zero-length associated data"; a failed decryption does not advance `n`; nonce exhaustion "must" end the session.
- Section 5.1: `n = 2^64-1` is reserved.
- Section 11.4: an application may send `n` with each transport message and call `SetNonce()`, and must then reject repeated values.
- Section 7.7: in KK, handshake message 1 has sender authentication property 1 ("vulnerable to key-compromise impersonation"), and transport payloads get source 2 and destination 5 (KCI-resistant authentication and strong forward secrecy). The responder's transport payloads get those properties "only if" it has received the initiator's first transport payload.
- Section 12.1: a DH function may signal an error for all-zero output instead of returning it.

## Decision

1. **Own implementation, spec verbatim.** `Packages/StarlingIdentity/Sources/StarlingIdentity/Noise/` implements `CipherState`, `SymmetricState`, and `HandshakeState` as sections 5, 7, and 12 state them, on CryptoKit `Curve25519.KeyAgreement`, `ChaChaPoly`, `SHA256`, and `HMAC<SHA256>`. HKDF is written out step by step as section 4.3 gives it. Only XX and KK are defined. Nothing Starling-specific is inside these types. CryptoKit's error on low-order points is the section 12.1 alternative and fails the handshake.
2. **Vectors.** The XX and KK entries of two independent vector files, cacophony (Unlicense) and snow (Apache-2.0 OR MIT, used under MIT), are vendored unmodified with their licenses in `Tests/StarlingIdentityTests/Vectors/README.md`. Tests check every handshake and transport ciphertext, the handshake hash, and both remote static keys.
3. **Framing.** One type byte per frame:
   - `0x01` and `0x02`: KK messages 1 and 2, with empty payloads.
   - `0x03`: transport, laid out as an 8-byte big-endian nonce, then the Noise transport message.
   - `0x10`: pairing traffic (ADR 0101), unauthenticated at this layer.

   The KK prologue is `Starling secure channel v1`, so a version mismatch fails the handshake instead of being negotiated. The transport plaintext starts with one kind byte: `confirm` (empty), `data`, or `confirmAck` (empty).
4. **Explicit, strictly increasing nonces** (section 11.4). The receiver accepts a nonce only if it is higher than every nonce it has already accepted on that session, then calls `SetNonce` and decrypts with zero-length associated data. This drops replayed and reordered frames. A lost frame does not desynchronize the session (upper layers already tolerate loss, ARCHITECTURE rule 5). Sends are serialized so nonces reach the link in the order they were assigned.
5. **Liveness before `peerAvailable`.** After KK message 2, the initiator immediately sends an encrypted `confirm`. The responder keeps a new session as pending until a frame decrypts under it. This has three effects:
   - A replayed message 1 never makes a peer look present.
   - A message 1 forged with a stolen responder key (the KCI case) cannot complete, because producing a valid frame needs the initiator's key.
   - Every responder payload gets the section 7.7 "2, 5" properties.

   The responder also keeps a 64-entry cache of answered initiator ephemeral keys (kept across link loss), and at most 4 pending sessions per peer.

   **Confirmation is acknowledged** (added after review finding MEDIUM 3). A single confirm can be lost or fail to send. On first connection the responder would then never announce the peer; on a rekey it would keep sending under a session the initiator had already dropped. So:
   - The responder answers every `confirm` on its live session with an encrypted `confirmAck`, retries included.
   - The initiator's new session counts as confirmed once any frame from the responder decrypts under it. Until then the initiator resends `confirm` every handshake timeout, up to the attempt count.
   - Until a newer session is confirmed, the initiator keeps two kinds of session for receiving only (added after the second review, finding 2):
     - the last confirmed session, which only a confirmed session can replace, so it survives any number of unconfirmed replacements;
     - every newer session replaced before it was confirmed, up to all the sessions one restart budget can create (`maxUnconfirmedRestarts + 1`; third review, finding 2), in case the responder switched to one of them. A frame that decrypts under one of these confirms it: it becomes the last confirmed session, kept until a newer one is confirmed.
   - If no acknowledgement ever arrives, the initiator starts a new handshake.
   - **One restart budget.** Every replacement of an unconfirmed session spends from the same budget of two, refilled only by authenticated progress (a frame from the responder on the current or a superseded session) or a link reset (added after the second review, finding 3). That covers an unacknowledged confirm, the nonce cap, and an explicit `reconnect`. A link that loses every confirmation therefore ends in silence rather than in endless handshakes.
   - **One admission gate** (fourth review, finding 3). Every new handshake goes through it, whether it comes from link-up, `reconnect`, the nonce cap, or a confirm timeout, and including a `reconnect` when no session is current. While unconfirmed sessions are retained, a new attempt is admitted only if it spends from the budget and if its later retirement could not evict a retained session the peer may still be using. Otherwise it waits for authenticated progress or a link reset.
   - **Admission comes after the lookup** (fifth review, finding 3). It is decided after the handshake's awaited pin lookup, immediately before the attempt is installed. Only one attempt per peer runs at a time; concurrent `reconnect`s coalesce.

   Each confirm has its own strictly increasing nonce, so a replayed confirm is dropped and cannot draw an acknowledgement.
6. **Who initiates.** Either side may send message 1 when a link comes up, on `reconnect(_:)`, or when a session rolls over. If both do, the lower `PeerID`'s handshake wins: the higher side abandons its own and answers. An initiator retries after 5 seconds, up to 3 attempts. That covers the gap between one phone finishing pairing and the other pinning the key.
7. **Session cap.** Each direction may send at most 2^20 messages per session. On reaching the cap, the sender stops sending on the session, starts a new handshake (within the decision 5 restart budget if the session was unconfirmed), and that one send fails with `peerUnreachable`. The exhausted session stays valid for receiving only until a newer one is confirmed, because the peer may still be sending on it. `CipherState` independently refuses the reserved nonce, so a nonce can neither repeat nor wrap (ADR 0003 care requirement 3). There is no time-based rekey; sessions end when the link drops or the app stops.
8. **Identity binding.** The wrapped transport's `localPeer` must equal the identity's key-derived `PeerID`, otherwise `start()` throws. Remote link IDs are treated as claims and looked up in `PairedPeerStore`. Frames from IDs with no pinned key are dropped. Transports must therefore report peers by key-derived ID (lane E2 note in `docs/requests/E1.md`).
   - Before any session is installed, the key it proves must hash to the claimed ID.
   - A session is installed in exactly two ways: the initiator completes a KK handshake, or a frame decrypts under a responder's pending session. A failed or unauthenticated handshake therefore never displaces or shadows the live session for that ID.
   - Lane E2's link table keys links by the `PeerID` in an unauthenticated hello (ADR 0110), so an OS-paired device can take over a friend's link. If the transport replaces the link silently, the live session stays, and the impostor's frames drop. If the transport first reports the friend gone, the session is dropped, because the link says the friend cannot be reached, and the impostor never gets a new one. Either way the attacker gets denial of service only.
   - `status(of:)` reports the claimed ID next to the proven key, plus per-claim drop counts.
9. **Sizes.** Outgoing plaintext is capped at `ProtocolLimits.maxEnvelopeBytes` (56 KiB). Ciphertext adds 26 bytes (type, nonce, kind, tag), which stays under `maxFrameBytes` (60 KiB).
10. **Silence.** Every rejected frame is dropped without a reply and without a distinguishing error. The only local trace is a drop counter (ADR 0003 care requirement 4).
11. **Revocation: one synchronous authority, and sessions stamped with an epoch** (first review HIGH 1; second review finding 1; third review finding 1; redesigned after the fourth review, because each round found a revocation race at a new await).

    **One authority per identity.** The app creates one `PinAuthority` for its identity and pinned-peer store, and injects it into every `SecureTransport` (LocalP2P, Wi-Fi Aware) and every `PairingService`. No component creates its own. All revocation state lives in the authority behind a `Synchronization.Mutex`: checks and updates are atomic and contain no suspension point. Only Keychain I/O is async.

    **State, per peer:**
    - `epoch`: a number that only moves forward (from a `GenerationTable`, decision 12).
    - `removing`: unpairs in progress.
    - `committing`: pairing commits in progress.
    - `quarantined`: a removal failed and the pin may still be stored.

    One pin lock, also in the authority, serializes every Keychain write (commits and removals).

    **Transitions** (each synchronous, under the mutex):

    | Event | Effect |
    |-------|--------|
    | `revoke(p)` (`disconnect`) | `epoch += 1` |
    | unpair begins | `epoch += 1`, `removing += 1` |
    | unpair ends (after the delete, under the pin lock) | `epoch += 1`, `removing -= 1`; if the delete failed, `quarantined = true`, otherwise `false` |
    | commit begins (under the pin lock) | allowed only if `epoch == e0` (the epoch when its ceremony started), `removing == 0`, and not quarantined; then `committing += 1` |
    | commit ends | `committing -= 1`; if `epoch != e0` after the save, delete the pin (quarantine if that fails) and `epoch += 1` |
    | lookup | refused if `removing`, `committing`, or `quarantined`; otherwise read the pin, then accept it only if the epoch and those flags are unchanged; returns the pin and its epoch `e` |

    **Sessions carry their epoch.** A handshake records the epoch `e` of the lookup that authenticated it, and the session it creates is stamped with `e`. It is installed only if `e` is still the peer's epoch. Then, on every transport sharing the authority, every action that makes a session observable happens inside one authority mutex section that first checks the stamp against the peer's current epoch (`PinAuthority.ifCurrent`, added after the fifth review):
    - sealing a frame (the check, taking the nonce, encrypting);
    - accepting a frame (the check, committing the receive state, publishing the plaintext);
    - announcing the peer.

    A session whose epoch is behind is dead and is torn down on first touch. Observers (transports, pairing services) are also notified of revocations, but only for liveness: correctness rests on these checks.

    **Notifications are never awaited** (issue #32, after the sixth review). Each observer is notified in its own task, after the delete in an unpair, and the same way for `disconnect`, `revoke`, and commit rollback. A pairing service's reaction includes a network send (the ceremony's cancel notice), which can stall. So the only thing an unpair awaits is Keychain I/O under the pin lock: it finishes, and the pin is gone, even while every send is stalled.

    **Notices carry their epoch** (focused review of #33). Because notices run later, one can arrive after newer work has begun: a reconnect's lookup, a handshake, a session, or a new ceremony, all under the new epoch. So every notice carries the epoch its revocation produced, and observers clean up only what is older:
    - A transport removes only sessions and handshakes stamped with an older epoch, and does not move its generation, so a newer lookup survives.
    - A pairing service cancels a ceremony only if it started under an older epoch.

    **The commit decision is one section** (fifth review). After its save, a commit compares the epoch and, if unchanged, ends (`committing -= 1`) in the same section. If the epoch moved, the commit stays in progress (lookups refused) until its rollback ends it.

    **Invariant.** For every peer `p` and every transport sharing the authority:
    1. A frame is sent or delivered on a session only if the session's epoch equals `p`'s current epoch at that moment.
    2. The epoch moves synchronously at the start of every revocation (before any await), at the end of every unpair, and on every commit rollback.

    It follows that:
    - (a) No session authenticated before a revocation began is usable after it began, on any transport.
    - (b) No pin survives an unpair: the delete runs under the pin lock after every commit that began earlier, and a commit that saved and then saw the epoch move deletes its own pin. If a delete fails, the peer is quarantined and lookups refuse it.
    - (c) No session can be authenticated from a pin that an unpair or a commit might still remove, because lookups are refused while either is in progress. The end-of-unpair and rollback epoch moves kill anything that slipped through regardless.
    - (d) A commit leaves a pin only if no revocation began between its ceremony's start and its end.

    **Audit: every read of revocation state and what covers its action** (fifth review). The next review can check this list instead of searching for sites.

    | # | Where | Reads | Acts | Covered by |
    |---|-------|-------|------|------------|
    | 1 | `PinAuthority.commit`, admission | epoch, blocked | `committing += 1`, then save | One section |
    | 2 | `PinAuthority.commit`, decision | epoch | end the commit, or stay in progress and roll back | One section (fifth review, finding 1) |
    | 3 | `PinAuthority.commit`, rollback end | (none) | epoch moves, `committing -= 1`, quarantine | One section |
    | 4 | `PinAuthority.beginRemoval`, `markRevoked`, `endRemoval` | (none) | epoch moves, removal mark | One section each |
    | 5 | `PinAuthority.pinned` | blocked, epoch, before and after the store read | returns `(pin, e)` | Two sections around the await. Fails closed: either can only refuse, and the result is only a candidate stamped with `e`; nothing is sealed, accepted, or announced on it without rows 9 to 11. |
    | 6 | `SecureTransport.pinnedKey` | epoch, blocked after the lookup | builds handshake state stamped with `e` | Not one section, by design: the stamp is what rows 9 to 11 check atomically. |
    | 7 | `SecureTransport.receiveHandshake2` | `initiation.epoch` against the epoch | installs the initiator session stamped with it | Not one section, by design: installing is not observable. The confirm it sends goes through row 10, and the announcement through row 11. |
    | 8 | `SecureTransport.receiveHandshake1` | (stamp from row 6) | adds a pending session | Not observable until promoted, which happens only inside row 9. |
    | 9 | `SecureTransport.receiveTransport` | stamp against epoch | commits the receive state (nonce window, promotion, confirmation), announces, yields the plaintext | One section via `ifCurrent` (fifth review, finding 2). Decryption runs before it, on copies. |
    | 10 | `SecureTransport.seal` | stamp against epoch | takes the nonce, encrypts, stores the cipher state | One section via `ifCurrent` (fifth review, finding 2) |
    | 11 | `SecureTransport.announce` | stamp against epoch | yields `peerAvailable` | One section via `ifCurrent` |
    | 12 | `SecureTransport.purgeStale` | epoch | removes stale sessions and handshakes | Not one section, fails safe: a stale read can only keep a session that rows 9 to 11 then reject. |
    | 13 | `SecureTransport.status` | (through row 12) | reports the proven key | Diagnostic only; may report a key revoked an instant later. |
    | 14 | `PairingService.pair` | epoch | records the ceremony's `e0` | No action: `e0` is compared only in rows 1 and 2. |

    Session generations, admission, and retained sessions are actor-isolated to one `SecureTransport` and not shared, so actor isolation covers them; admission is decided after the pin lookup, immediately before the attempt is installed (decision 5).

    **Deterministic tests.** `PinAuthority` has a test checkpoint hook: named points (an epoch read, a commit decision) where a test runs a synchronous action, such as moving the epoch as another transport would. It is nil in production, never awaits, and never runs under the state mutex. The tests hold each path at each of its awaits, or act at a checkpoint, with two `SecureTransport`s sharing one authority:
    - the commit's save, before and after the write;
    - the unpair's removal, before and after the delete;
    - the revocation notice;
    - a `disconnect` during a held commit.
12. **Bounded state** (third review, finding 3). Only peers with a pinned key get per-peer state; link presence is a separate set cleared on link loss, so an unauthenticated claim alone leaves nothing behind. On link loss a peer keeps only its replay cache, and a revoked peer keeps nothing. Idle state past `maxTrackedPeers` (default 1,024) is forgotten.

    Session generations and the authority's epochs live in a bounded `GenerationTable`:
    - Values come from a single counter that only grows.
    - Past capacity, the oldest entry is evicted.
    - Peers without an entry read a floor that every eviction raises above every value handed out so far.

    So a reading taken before an eviction never matches after it. Eviction can only make a stale-lookup check fail (the caller tries again later), never pass wrongly.
13. **Test-only dependency.** The test target depends on `StarlingTransport` for `LoopbackTransport`. The library target depends only on `StarlingCore` and Apple frameworks (CryptoKit, Security). Approved by the Orchestrator on 2026-09-30.

## Consequences

- One small, spec-shaped implementation to audit; the Codex review required by ADR 0003 care requirement 7 has a clear boundary: the `Noise/` directory, `SecureTransport.swift`, `SecureWire.swift`, and the pairing code (ADR 0101).
- Message sizes are visible on the wire. Noise section 13 recommends padding; there is none yet. Revisit before the relay (Phase 2) makes traffic observable by a third party.
- The session design assumes a live, in-order link. The Phase 2 relay needs a one-way pattern or HPKE (ADR 0003 decision 3) and its own replay rules.
- Frames that arrive on a receive-only session (decisions 5 and 7) are delivered even while the peer is reported unavailable after a rollover. They are authenticated; only sending is paused.
- Once the restart budget is spent, the peer stays unreachable until a session is confirmed (for example the peer reconnects), the link comes back, or the app calls `reconnect(_:)` with no current session.
- A link-level attacker can still deny service: drop frames, or replay old message 1s to fill the pending slots during a real handshake. Retries recover from the second once the attacker stops.
- Pairing can end up one-sided (ADR 0101). The paired side's handshakes then fail silently after 3 attempts, and it looks like the friend is offline.
- Key material in memory is not zeroized. Swift `Data` gives no such guarantee. Private keys stay inside CryptoKit types except for the one Keychain write.

## Sources

- Noise Protocol Framework, revision 34: https://noiseprotocol.org/noise.html (sections 4.3, 5, 7.5, 7.7, 11.2, 11.4, 12, 13)
- cacophony vectors (Unlicense): https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt
- snow vectors (Apache-2.0 OR MIT): https://github.com/mcginty/snow/blob/main/tests/vectors/snow.txt
- Bitchat Noise implementation: https://github.com/permissionlesstech/bitchat/tree/main/bitchat/Noise
- swift-libp2p/swift-noise: https://github.com/swift-libp2p/swift-noise
- snow README ("has not received any formal audit"): https://github.com/mcginty/snow
- CryptoKit: https://developer.apple.com/documentation/cryptokit
