# ADR 0003: Authenticate and encrypt at the message layer

- Status: **Accepted** by the owner on 2026-09-30, with the instruction to be careful (see "Care requirements"). Implementation: Phase 1, lane E1.
- Date: 2026-09-29
- Owner: Orchestrator

## Context

The brief asks for a choice between a Noise handshake and "QUIC/TLS with pinned raw keys." Verification found the second option is much harder than it sounds on Apple platforms:

- Network framework TLS-PSK "doesn't work with QUIC, it doesn't support TLS 1.3, and it only works with the older Network framework API" (TN3213).
- Mutual TLS needs a `SecIdentity` on each device, and "Apple platforms have no API to" create one; TN3213 points to the swift-certificates package. There is no raw-public-key (RFC 7250) option.
- QUIC always runs TLS, so QUIC without real identities means embedding one shared identity and disabling trust checks (TN3213 describes this as having no meaningful security).
- Remote coordination (brief 3.4) is store-and-forward through a relay. TLS only protects a live connection to the relay. End-to-end encryption of stored blobs needs message-layer crypto regardless.
- Wi-Fi Aware already encrypts at the link layer between OS-paired devices, but that binds devices, not Starling identities.

## Decision

1. **Transports carry opaque frames and do not authenticate.** A transport's notion of "who sent this" is a claim. Link-layer or TLS encryption, where a transport has it, is defense in depth only.
2. A **secure channel layer** in `StarlingIdentity` (Phase 1) sits between the envelope codec and every transport. It authenticates peers with the identity keys pinned at pairing and encrypts every Starling message end to end.
3. Default mechanism: the Noise Protocol Framework on CryptoKit primitives (X25519, ChaChaPoly, SHA-256), the same suite Bitchat uses.
   - Pairing: `Noise_XX`, with a short authentication string derived from the handshake hash that both people compare, so an attacker in the room cannot sit in the middle.
   - Paired peers, live link: `Noise_KK` (both static keys already pinned).
   - Paired peers, through a relay: a one-way pattern (`Noise_K`) or HPKE auth mode (RFC 9180, in CryptoKit) using the same pinned keys. Lane L picks one in Phase 2.
4. `PeerID` becomes a hash of the peer's static public key in Phase 1, so an ID cannot be claimed without the key.

## Consequences

- One scheme covers Loopback, LocalP2P, Wi-Fi Aware, and the relay, so there is one thing to audit and it runs in the simulator without radios.
- We own security-critical code. Mitigations: implement against the Noise spec revision 34 test vectors, keep the code small, or adopt an existing Swift Noise implementation if lane E finds one with a credible review. No privacy claim ships before `docs/THREAT_MODEL.md` (brief 3.5).
- Phase 0 LocalP2P is **unauthenticated and unencrypted**. It is labeled as such in code and UI and carries only spike data.
- If the owner prefers TLS, the fallback is QUIC with per-device self-signed certificates from swift-certificates and a pinning validator, plus a separate message-layer scheme for the relay.

## Care requirements

Because we own this code, lane E1 must meet all of these before its PR can merge:

1. Implement Noise exactly as specified in revision 34 (no custom variations), using only CryptoKit primitives.
2. Pass the published Noise test vectors for every pattern used (XX, KK, and any one-way pattern).
3. Nonces never repeat; a session is torn down before its counter can wrap.
4. Decryption failures, unknown keys, and replays are dropped without distinguishing error details on the wire.
5. Private keys live only in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and are never logged or encoded.
6. Adversarial tests over Loopback: tampered, truncated, replayed, reordered, and wrong-key frames, and the simulator's impersonation scenario flips from known issue to passing.
7. A Codex review focused on the cryptography, plus `docs/THREAT_MODEL.md` updated, before any privacy claim is made.

## Sources

- TN3213, "Plan for security": https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- Noise Protocol Framework: https://noiseprotocol.org/noise.html
- RFC 9180 (HPKE): https://www.rfc-editor.org/rfc/rfc9180
- Bitchat whitepaper: https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md
- Wi-Fi Aware overview (link-layer security between paired devices): https://developer.apple.com/documentation/wifiaware
