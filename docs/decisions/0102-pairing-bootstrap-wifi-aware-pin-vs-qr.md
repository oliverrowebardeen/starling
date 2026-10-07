# ADR 0102: Pairing bootstrap: Wi-Fi Aware PIN first, no QR or tap fallback

- Status: Proposed (answers brief open question 3; needs the owner's agreement)
- Date: 2026-09-30
- Owner: Lane E1 (Identity and secure channel)

## Context

Brief open question 3: "Is Wi-Fi Aware PIN pairing too much friction? Would a QR or tap-based key exchange over Network framework be a better trust bootstrap?"

### What Wi-Fi Aware pairing is

- **Mandatory.** Apple DTS, forum thread 791628, answering "Is this pairing mandatory?": "Yes. That's how Wi-Fi Aware works." The framework overview says the same: "When paired, your app can create secure, authenticated, and encrypted peer-to-peer connections between paired devices."
- **A one-time PIN, displayed on one phone and typed on the other.** WWDC25 session 228: "the incoming request and a PIN code is displayed on the publisher side and entered on the subscriber side." Apple's Accessory Design Guidelines (2026-09-21, chapter 56) specify "a 6-digit PIN as the pairing method."
- **Persistent.** Apple DTS in forum thread 837110: "these pairings persist indefinitely." Removal happens in Settings; `WAPairedDevice` has no unpair call.
- **Device-level, not Starling-level.** The app learns a `WAPairedDevice.id`, "stable for the lifetime of a single app install on a single device," plus names that "may be intercepted or manipulated by an attacker." It gets no keys. So the OS pairing cannot pin a Starling identity by itself.
- **There is one hook, `WAConnection.deriveSharedSecret(for:method:context:)`** (iOS 26.4 and later, verified in Apple's documentation JSON on 2026-09-30). It derives "a unique, high-entropy shared secret for this network connection" that both apps get on the same connection, meant to "pair and setup security for higher layer network protocols ... without additional user action." Apple says not to save or reuse the secret, and to "derive unique longer-term asymmetric keys for those protocols when pairing them."
- **Hardware.** iPhone 12 and later. Every phone Starling targets (Apple Intelligence: iPhone 15 Pro and later) has it.

### Starling today, after lanes E1 and E2

Pairing a friend over Wi-Fi Aware takes two steps:

1. The OS pairing: pick the phone, type the PIN (lane E2, ADR 0111).
2. The Starling ceremony over the new link: compare a 6-digit code and tap confirm on both phones (ADR 0101).

The first step is unavoidable. The second step is there because the OS pairing does not authenticate Starling keys.

### Alternatives

| Option | User action | Authenticates | Availability |
|--------|-------------|---------------|--------------|
| QR code | One phone shows a code, the other scans it | The displayed data to the scanner, one way; mutual needs a second scan or a code comparison | VisionKit `DataScannerViewController` needs an A12 or later chip, so every iOS 27 iPhone has it; it needs camera permission |
| NFC tap | n/a | n/a | Card emulation (`CardSession`) is limited to payments, keys, transit, badges, and similar uses under a commercial agreement. Phone-to-phone data exchange is not an eligible use. |
| NameDrop-style tap | n/a | n/a | No public API |
| Nearby Interaction | n/a | Nothing by itself (it needs tokens exchanged over another channel) | UWB phones |
| LocalP2P (Bonjour plus AWDL) with the ADR 0101 code | Tap Pair on both phones, compare the code | Starling keys, through the code | Works today, with no OS pairing |

### Usability evidence

- In comparative studies, **copy-and-enter** (the Wi-Fi Aware PIN model) had essentially no security failures.
- **Compare-and-confirm** (the ADR 0101 code) had 0 to 20% security failures across methods and studies (Kainda et al., SOUPS 2009; Uzun et al., USEC 2007).
- Signal users mostly skipped or misread safety-number checks (Schröder et al., EuroUSEC 2016; Vaziripour et al., SOUPS 2017).

## Decision

1. **Wi-Fi Aware PIN pairing is the bootstrap for v1.** It is mandatory for the Wi-Fi Aware transport anyway, happens once per friend, uses the pairing model with the best measured security, and every target phone supports it. The friction worth removing is the second step, not the PIN.
2. **Phase 1 ships both steps.** The OS pairing, then the ADR 0101 ceremony over the new link. This is secure without depending on any Wi-Fi Aware internals, and the same ceremony works over any link.
3. **Considered, not adopted: binding the Starling handshake to the OS pairing** to drop the code comparison on Wi-Fi Aware links.
   - Both apps would call `deriveSharedSecret` on the connection with a Starling-specific protocol name.
   - They would run `Noise_XXpsk3_25519_ChaChaPoly_SHA256` with that secret as the PSK. This is a standard Noise pattern, and cacophony publishes vectors for it.
   - A man in the middle would then have to be the device the owner typed the PIN into.
   - It would need `WiFiAwareTransport` to expose a per-link secret (`docs/requests/E1.md`), XXpsk3 vectors, and a device test. Starling keeps the code comparison (decision 2).
4. **No QR or tap fallback in Phase 1.**
   - No target phone lacks Wi-Fi Aware.
   - NFC and tap have no usable public API.
   - The LocalP2P path with the ADR 0101 code already covers development, the Mac peer tool, and a Wi-Fi Aware outage.

## Consequences

- Pairing a friend means typing a PIN and then comparing a code. The checklist in `docs/checklists/phase-1-E1.md` measures how long the whole thing takes on real phones.
- The code comparison is the security-critical step. The UI (lane H) should show the code large, ask "Does Bob's phone show 123 456?", and never pre-select "match".
- Unpairing in Starling (remove from `PairedPeerStore`, then `SecureTransport.disconnect`) does not remove the OS pairing, and removing the OS pairing in Settings does not remove the Starling pin. Lane H should explain both in the UI.

## Sources

- Wi-Fi Aware framework: https://developer.apple.com/documentation/wifiaware
- `WASharedSecret` and `deriveSharedSecret(for:method:context:)` (iOS 26.4): https://developer.apple.com/documentation/wifiaware/washaredsecret
- `WAPairedDevice.id`: https://developer.apple.com/documentation/wifiaware/wapaireddevice/id-swift.property
- DeviceDiscoveryUI: https://developer.apple.com/documentation/devicediscoveryui
- WWDC25 session 228, "Supercharge device connectivity with Wi-Fi Aware": https://developer.apple.com/videos/play/wwdc2025/228/
- Apple Developer Forums, pairing is mandatory: https://developer.apple.com/forums/thread/791628
- Apple Developer Forums, pairings persist: https://developer.apple.com/forums/thread/837110
- Accessory Design Guidelines, chapter 56 (Wi-Fi Aware): https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf
- VisionKit `DataScannerViewController.isSupported`: https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/issupported
- NFC and SE Platform: https://developer.apple.com/support/nfc-se-platform/
- Nearby Interaction sessions: https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session
- TN3213: https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- Noise revision 34, section 9 (PSK patterns): https://noiseprotocol.org/noise.html
- Kainda, Flechais, Roscoe, SOUPS 2009: https://cups.cs.cmu.edu/soups/2009/proceedings/a11-kainda.pdf
- Uzun, Karvonen, Asokan, USEC 2007: https://sprout.ics.uci.edu/pubs/usability_analysis_method.pdf
- Schröder et al., EuroUSEC 2016: https://www.ndss-symposium.org/wp-content/uploads/2017/09/09-when-signal-hits-the-fan-on-the-usability-and-security-of-state-of-the-art-secure-mobile-messaging.pdf
- Vaziripour et al., SOUPS 2017: https://www.usenix.org/system/files/conference/soups2017/soups2017-vaziripour.pdf
