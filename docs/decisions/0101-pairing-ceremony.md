# ADR 0101: Pairing ceremony: Noise XX plus a committed 6-digit code

- Status: Accepted (code merged on main; status updated 2026-10-06); decision 2's link-loss rule amended by ADR 0260
- Date: 2026-09-30 (revised the same day after four Codex reviews of PR #16; see decision 2)
- Owner: Lane E1 (Identity and secure channel)

## Context

ADR 0003 specifies pairing as `Noise_XX` "with a short authentication string derived from the handshake hash that both people compare, so an attacker in the room cannot sit in the middle." `StarlingCore.PairingSession` gives the UI a `confirmCode(String)` event and `confirm(codesMatch:)`.

A code taken from the handshake hash alone does not give the protection people expect from 6 digits:

- A man in the middle runs two XX sessions, one with each victim.
- In the session where the attacker is the XX initiator, it sends the last message (`-> s, se` plus payload) after seeing everything the victim contributed.
- The attacker can therefore change its static key or payload and recompute until that session's code equals the code from the other session.
- A 6-digit code needs about 10^6 tries, roughly 2^20 X25519 operations and well under a second on a laptop.

The standard fix is to make each side commit to its randomness before seeing the other side's. Bluetooth numeric comparison does this, and NIST SP 800-121r2 credits it with MITM protection.

Usability: in comparative studies, compare-and-confirm had 0 to 20% security failures, while copy-and-enter had almost none (Kainda et al., SOUPS 2009; Uzun et al., USEC 2007). ADR 0102 discusses what that means for Starling.

## Decision

1. **Messages.** Pairing runs on any `Transport`, usually `SecureTransport.pairingLink` (ADR 0100 type `0x10`). The prologue is `Starling pairing v1`. The peer with the lower `PeerID` is the XX initiator.

   | Step | Direction | Content |
   |------|-----------|---------|
   | hello | both | Empty. Sent on start, and by the responder again whenever it gets one, so either owner may tap Pair first. |
   | message 1 | I to R | `-> e` |
   | message 2 | R to I | `<- e, ee, s, es`. Payload: `SHA-256("Starling pairing commitment v1" ‖ nR)`, where nR is 32 random bytes. |
   | message 3 | I to R | `-> s, se`. Payload: nI, 32 random bytes. |
   | reveal | R to I | Encrypted under the XX transport keys: nR. The initiator checks it against the commitment and abandons the ceremony on a mismatch. |
   | code | both | Take `SHA-256("Starling pairing code v1" ‖ h ‖ nI ‖ nR)`, read the first 8 bytes as a big-endian integer, reduce it mod 10^6, and zero-pad to 6 digits. `h` is the XX handshake hash, used as a channel binding (Noise section 11.2). |
   | answer | both | Encrypted: `accept`, `reject`, or `cancel`. |

   Every value the attacker controls is fixed before it learns an honest party's nonce. The code is therefore uniform from its point of view, and one ceremony succeeds for it with probability 10^-6. That is the Bluetooth target. Noise itself is unchanged; the commitment and nonces travel in XX payloads and transport messages.
2. **Both owners confirm.**
   - A side saves `PairedPeer` only after its own owner confirms and the peer's `accept` has arrived.
   - After that point the ceremony is committed: a late cancel or link loss no longer changes the outcome.
   - A rejection on either side yields `.failed(.codeMismatch)` on both. Cancel, timeout (30 s to reach the code, 120 s to answer), and link loss each fail the ceremony, and nothing is stored on that side.
   - Every local ending (reject, cancel, timeout, abandon) is final before anything is awaited. The notice to the peer is sealed while the keys still exist, the ceremony finishes, and only then is the notice sent, best effort. An `accept` that arrives while the notice is in flight finds the ceremony finished and cannot pin the peer. (Review finding HIGH 2: before this fix, a cancel or timeout that was still sending its notice could be overtaken by the peer's accept and commit the pairing.)
   - **Unpairing wins** (second through fourth reviews). A ceremony commits its pin only through the device's one `PinAuthority`, which every unpair on every transport also goes through, and is cancelled when its peer is revoked. The authority commits only if the peer's epoch has not moved since the ceremony started, under the same lock as removals. If the epoch moves during the save, the commit rolls back: it removes the pin and moves the epoch again, which kills any session authenticated meanwhile on every transport. The ceremony then ends `.failed(.cancelled)` (ADR 0100 decision 11).
3. **Checks on the remote key.**
   - It must hash to the `PeerID` the link claimed, so `SecureTransport` can find it later.
   - It must not be our own key. Either failure abandons the ceremony.
4. **Robustness.**
   - Frames that do not parse, decrypt, or fit the current step are dropped, so injected traffic cannot derail a ceremony once keys exist.
   - Before keys exist, an unauthenticated `abort` can end a ceremony. That is a denial of service only; someone jamming the radio can do the same.
5. **Nicknames** are given when a ceremony starts, validated immediately, and never sent.

## Consequences

- The ceremony adds one message (the reveal) beyond XX's three. It takes about the same time as the handshake alone.
- **Pairing can end one-sided.** If the last `accept` is lost, the side that sent it has not seen the other's and does not save; the other side does. The paired side's KK handshakes then fail silently (ADR 0100). The owner sees the friend as offline until they pair again. ADR 0260 decision 2 later made a finished ceremony resend its last messages, so a single lost final `accept` still arrives.
- Compare-and-confirm relies on people actually comparing. The studies above show many do not. ADR 0102 considered removing this step on Wi-Fi Aware links by binding to the OS pairing; Starling keeps the code on every link.
- `PairingFailure` has no storage case. A Keychain write failure after both confirmations surfaces as `.protocolError` (`docs/requests/E1.md`).

## Sources

- Noise Protocol Framework revision 34, section 11.2 (channel binding): https://noiseprotocol.org/noise.html
- NIST SP 800-121 Rev. 2 Upd. 1, section 3.2.2 (numeric comparison and passkey entry): https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-121r2-upd1.pdf
- Bluetooth Core Specification v6.2, Vol 1 Part A section 5.2.3 ("a 1 in 1,000,000 chance that a MITM could mount a successful attack"): https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-62/out/en/architecture,-change-history,-and-conventions/architecture.html
- S. Vaudenay, "Secure Communications over Insecure Channels Based on Short Authenticated Strings," CRYPTO 2005 (the commit-then-reveal SAS construction): https://doi.org/10.1007/11535218_19
- R. Kainda, I. Flechais, A. W. Roscoe, "Usability and Security of Out-Of-Band Channels in Secure Device Pairing Protocols," SOUPS 2009: https://cups.cs.cmu.edu/soups/2009/proceedings/a11-kainda.pdf
- E. Uzun, K. Karvonen, N. Asokan, "Usability Analysis of Secure Pairing Methods," USEC 2007: https://sprout.ics.uci.edu/pubs/usability_analysis_method.pdf
