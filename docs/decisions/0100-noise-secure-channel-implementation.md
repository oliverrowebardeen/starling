# ADR 0100: Noise secure channel implementation

- Status: Proposed
- Date: 2026-09-30
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

   The KK prologue is `Starling secure channel v1`, so a version mismatch fails the handshake instead of being negotiated. The transport plaintext starts with one kind byte: `confirm` (empty) or `data`.
4. **Explicit, strictly increasing nonces** (section 11.4). The receiver accepts a nonce only if it is higher than every nonce it has already accepted on that session, then calls `SetNonce` and decrypts with zero-length associated data. This drops replayed and reordered frames. A lost frame does not desynchronize the session (upper layers already tolerate loss, ARCHITECTURE rule 5). Sends are serialized so nonces reach the link in the order they were assigned.
5. **Liveness before `peerAvailable`.** After KK message 2, the initiator immediately sends an encrypted `confirm`. The responder keeps a new session as pending until a frame decrypts under it. This has three effects:
   - A replayed message 1 never makes a peer look present.
   - A message 1 forged with a stolen responder key (the KCI case) cannot complete, because producing a valid frame needs the initiator's key.
   - Every responder payload gets the section 7.7 "2, 5" properties.

   The responder also keeps a 64-entry cache of answered initiator ephemeral keys (kept across link loss), and at most 4 pending sessions per peer.
6. **Who initiates.** Either side may send message 1 when a link comes up, on `reconnect(_:)`, or when a session rolls over. If both do, the lower `PeerID`'s handshake wins: the higher side abandons its own and answers. An initiator retries after 5 seconds, up to 3 attempts. That covers the gap between one phone finishing pairing and the other pinning the key.
7. **Session cap.** Each direction may send at most 2^20 messages per session. On reaching the cap, the sender tears the session down and starts a new handshake, and that one send fails with `peerUnreachable`. `CipherState` independently refuses the reserved nonce, so a nonce can neither repeat nor wrap (ADR 0003 care requirement 3). There is no time-based rekey; sessions end when the link drops or the app stops.
8. **Identity binding.** The wrapped transport's `localPeer` must equal the identity's key-derived `PeerID`, otherwise `start()` throws. Remote link IDs are treated as claims and looked up in `PairedPeerStore`. Frames from IDs with no pinned key are dropped. Transports must therefore report peers by key-derived ID (lane E2 note in `docs/requests/E1.md`).
   - Before any session is installed, the key it proves must hash to the claimed ID.
   - A session is installed in exactly two ways: the initiator completes a KK handshake, or a frame decrypts under a responder's pending session. A failed or unauthenticated handshake therefore never displaces or shadows the live session for that ID.
   - Lane E2's link table keys links by the `PeerID` in an unauthenticated hello (ADR 0110), so an OS-paired device can take over a friend's link. If the transport replaces the link silently, the live session stays, and the impostor's frames drop. If the transport first reports the friend gone, the session is dropped, because the link says the friend cannot be reached, and the impostor never gets a new one. Either way the attacker gets denial of service only.
   - `status(of:)` reports the claimed ID next to the proven key, plus per-claim drop counts.
9. **Sizes.** Outgoing plaintext is capped at `ProtocolLimits.maxEnvelopeBytes` (56 KiB). Ciphertext adds 26 bytes (type, nonce, kind, tag), which stays under `maxFrameBytes` (60 KiB).
10. **Silence.** Every rejected frame is dropped without a reply and without a distinguishing error. The only local trace is a drop counter (ADR 0003 care requirement 4).
11. **Test-only dependency.** The test target depends on `StarlingTransport` for `LoopbackTransport`. The library target depends only on `StarlingCore` and Apple frameworks (CryptoKit, Security).

## Consequences

- One small, spec-shaped implementation to audit; the Codex review required by ADR 0003 care requirement 7 has a clear boundary: the `Noise/` directory, `SecureTransport.swift`, `SecureWire.swift`, and the pairing code (ADR 0101).
- Message sizes are visible on the wire. Noise section 13 recommends padding; there is none yet. Revisit before the relay (Phase 2) makes traffic observable by a third party.
- The session design assumes a live, in-order link. The Phase 2 relay needs a one-way pattern or HPKE (ADR 0003 decision 3) and its own replay rules.
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
