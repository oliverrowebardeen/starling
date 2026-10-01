# ADR 0100: Noise secure channel implementation

- Status: Proposed
- Date: 2026-09-30 (revised the same day after three Codex reviews of PR #16; see decisions 5, 7, 11, and 12)
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
   - **One restart budget.** Every replacement of an unconfirmed session spends from the same budget of two, refilled only when a session is confirmed or the link comes back (added after the second review, finding 3). That covers an unacknowledged confirm, the nonce cap, and an explicit `reconnect`. A link that loses every confirmation therefore ends in silence rather than in endless handshakes.

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
11. **Revocation is immediate, and one authority orders it** (first review HIGH 1; extended after the second review's finding 1; made structural after the third review's finding 1, the third round in which unpair and pairing raced at a new await).

    `PinAuthority` is the one authority over pinned keys. Every pin mutation goes through it: a pairing commit, or an unpair's removal. So does every use of a pin for a handshake. **Invariant:** once an unpair of a peer has begun, no pin for that peer survives it, no lookup that overlaps it returns a pin, and no session with the peer exists after its first await. The rules that make it hold:
    - **Mark first.** A revocation takes its mark synchronously, before any await. It moves the peer's revocation token, and an unpair also records a removal in progress until the pin is gone. `SecureTransport.unpair(_:)` ends every session and handshake with the peer in the same synchronous step, then notifies observers (`PairingService` cancels its ceremony) and removes the pin.
    - **One lock for mutations.** Pairing commits and unpair removals run one at a time under one async lock, so they never interleave, whatever they await. A commit saves only if the token has not moved since its ceremony began and no removal is in progress. It checks the token again after the save; if a revocation started meanwhile, it removes the pin before releasing the lock. No pin is left behind, even when the save already landed.
    - **Lookups are refused while unpairing.** A lookup returns nothing while a removal is in progress, and discards what it read if the token moved. A pin that a commit will undo exists only while the removal mark is set: the mark is set before the commit's post-save check and cleared only after the removal, which waits for the commit to release the lock. So no lookup can return that pin. Lookups do not take the lock, so a slow save cannot stall the event loop.
    - **Stale continuations are void.** `SecureTransport` also keeps a per-peer session generation, moved by every teardown, rollover, and revocation. A lookup that resumes under a different generation or revocation token returns nothing, and handshake state is created synchronously after that check.
    - **Pairing cannot bypass the authority.** `PairingService` is created with the `SecureTransport` (sharing its authority and pairing link) or with an explicit `PinAuthority`, and commits only through it.

    The tests hold each path at each of its awaits and check the invariant: the commit's save before and after the write, and the unpair's removal before and after the delete and its revocation notice.
12. **Bounded state** (third review, finding 3). Only peers with a pinned key get per-peer state; link presence is a separate set cleared on link loss, so an unauthenticated claim alone leaves nothing behind. On link loss a peer keeps only its replay cache, and a revoked peer keeps nothing. Idle state past `maxTrackedPeers` (default 1,024) is forgotten.

    Session generations and revocation tokens live in a bounded `GenerationTable`:
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
