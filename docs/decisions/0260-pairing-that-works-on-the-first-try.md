# ADR 0260: Pairing that works on the first try

- Status: Proposed
- Date: 2026-10-02
- Owner: P15-G (pairing reliability)
- Amends: ADR 0101 (decision 2's link-loss rule), ADR 0110 (decision 3, symmetric roles), ADR 0145 (decisions 2 and 4), ADR 0202 (decision 3, when notifications are offered)

## Context

Oliver's two-phone test on 2026-10-02 (issue #95): "Pair a friend" kept failing after the phones paired and the code was entered, and worked after about 100 tries. The "Waiting for the other phone" progress was not centered, the flow was clearly not as clean as AirDrop, and the friend ended up named after their phone (for example "Riley's iPhone").

There were no logs from the phones. So the causes were first reproduced over Loopback (`PairingReliabilityTests`, run against main at d0c9ca0 before any fix). Eight of nine cases failed:

| Case on main | Result |
|---|---|
| One lost message 1, message 2, message 3, or encrypted frame | Stalled until the 30 s timeout. Every message was sent once. Only a lost hello survived, because both sides send one. |
| The responder's last `accept` lost after it committed | One-sided pairing: the committed side stopped listening, the other timed out with nothing stored. |
| The link down when the ceremony starts | Failed at once, "couldn't reach the other phone": a send that threw ended the ceremony. |
| The link drops and returns mid-ceremony | Failed at once ("transport failed"). |
| One phone starts over while the other is mid-handshake | Every new attempt timed out: the old ceremony ignored the new hello until both owners restarted together. |

Four more causes come from reading the code against the flow Oliver used:

- **Both owners had to start within 30 s of each other.** Each owner found the other phone in a list of hex IDs, typed a name, and tapped Pair. The first one's ceremony gave up 30 s after its tap and sent an abort that ended the second one's.
- **The two phones could pair on different links.** `PairingRoute` waited up to 5 s, per phone, for Wi-Fi Aware to report the friend, then fell back to Nearby. Two phones that saw Wi-Fi Aware at different times ran ceremonies on different links that never heard each other.
- **The Wi-Fi Aware link may never have formed.** Every phone published and subscribed the link service for every paired device (ADR 0110). A developer reports that two devices that both publish and subscribe never connect, while one publisher and one subscriber do (forum thread 811828, FB21527009, no Apple reply). We have no device evidence the link ever came up. The picker path waits for exactly this link (`peerID(for:waitingUpTo:)`), and an eventual success fits the Nearby (Bonjour and AWDL) link instead.
- **The name came first and was the device's.** The picker offered the device name as a one-tap fill.

Primary sources checked on 2026-10-02:

- Apple staff, forum thread 787570: "if you're app gets suspended then the connection closes"; Wi-Fi Aware "is pretty agressive about 'garbage collecting' idle connections ... the current value is a few minutes"; no state restoration.
- Apple staff, thread 837110: pairings "persist indefinitely", and the PIN is only needed the first time.
- Apple staff, thread 794271: `NWError.wifiAware(-11992)` maps through `NWError.wifiAware` to `WAError.noPairedDevices`.
- Apple staff, thread 838513: BSD Sockets do not work over Wi-Fi Aware; use Network framework (we do).
- iOS 27 SDK `WiFiAware.swiftinterface`: `WAPublisherListener.Devices` and `WASubscriberBrowser.Devices` take `.selected(_:)` and `.matching(_:)`, not only `.allPairedDevices`. `WAPairedDevice.name` is "the user-provided name of the device".
- `UNNotificationSettings.authorizationStatus` is `notDetermined` until the app asks; `UIApplication.openNotificationSettingsURLString` opens the app's notification settings.
- Not confirmed by a primary source, so not adopted: stopping the browser and listener once connected.

## Decision

1. **The ceremony tolerates loss** (`PairingService`):
   - While waiting on the other phone, it resends its last message every second.
   - A repeat of the message it last answered gets the same reply again.
   - Encrypted messages are resent together, in order, so the peer can decrypt them in sequence.
   - A failed send and a dropped link no longer end it. Only its timeouts do: 60 s to the code (was 30) and 120 s to answer.
2. **A finished ceremony lingers.** For 30 s it answers the peer's resends with its last messages (its accept, or its cancel), at most 3 times. So a lost final accept still arrives, and two finished phones cannot keep answering each other.
3. **Attempts are named.** Hellos and aborts carry an 8-byte attempt ID, new for each `pair` call.
   - Before a code is shown, a hello for a new attempt means the other phone started over, and this one restarts its handshake with fresh keys and fresh nonces. A nonce the other side has seen is never committed to again (ADR 0101's commit-then-reveal needs fresh randomness on every run).
   - A restart keeps the local attempt ID, so two phones never restart each other in a loop, and keeps the original timer, so restarts cannot extend a ceremony.
   - An abort ends a ceremony only if it names the attempt the ceremony answers, so a stale abort cannot end a newer one.
   - After a code is shown, nothing unauthenticated changes it (ADR 0101 decision 4 stands).
   - An empty hello or abort (a build from before this ADR) is read as naming no attempt.
4. **One pick is enough.**
   - The service lists phones whose hellos ask to pair with no ceremony running here (`requests()`, each kept for 5 s after its last hello).
   - The app joins a request while the sheet is open and idle. A request comes only from a phone whose owner picked this one, by its PeerID. The code comparison still decides.
   - An attacker in range can at most show a code that will not match, which is the denial of service an abort already allowed.
5. **One service over every link.** The app runs one `PairingService` over the pairing links of every `SecureTransport`, sending each frame on all of them and listening on all of them. The phones meet on whichever link works. `PairingRoute` is removed (ADR 0145 decision 4).
6. **One Wi-Fi Aware role per paired device** (`WiFiAwareTransport`, replacing ADR 0110 decision 3):
   - The phone whose owner picked in `WiFiAwareDevicePicker` subscribes and dials.
   - The phone showing `WiFiAwarePairingView` (the sheet calls `expectPairing`) publishes to a device paired meanwhile.
   - Both roles are tentative, lapsing after a minute without a link.
   - Once a link hello names the peer, both phones settle on the PeerID rule (the greater ID subscribes, as `LinkArbiter` prefers) and keep it in `UserDefaults`.
   - A device with no role yet takes a random role every 10 s until a link forms. Pairings made before this build therefore meet without being paired again.
   - Browse and listen cover only the devices their role names, and restart when that set changes. A listener restart closes the links it accepted, and their subscribers redial within a second. That happens only when a role changes.
7. **The name comes last.**
   - Both phones pin each other under "New friend".
   - The sheet then asks "What do you call them?", prefilled with a first name read from the phone's own name ("Riley's iPhone" gives "Riley"; English possessives, "iPhone de/von/di Riley", and "Riley的iPhone"). It is never the device name itself; with no usable name the field is empty.
   - The device name comes from that phone, so the prefill is only a suggestion the owner confirms, and `NicknameCheck` still warns about look-alikes (issue #46).
   - Done renames through the pin authority. The sheet cannot be swiped away at this step, so every friend gets a name the owner chose.
   - Device names label phones ("Connecting to Riley's iPhone", "Does Riley's iPhone show the same code?"), never people.
8. **A calm sheet.** Every step is one centered column with one main action:
   - Choosing: "Hold your phones close", with Find their phone, Let them find me, and the nearby list as a fallback.
   - Connecting and Waiting for the other phone: the status mark.
   - Check the code: large digits, with They match and They're different.
   - Then the name, and You're paired.
9. **Notifications after the first friend** (Oliver, 2026-10-02; amends ADR 0202 decision 3):
   - Right after a pairing, while iOS has not asked, the sheet shows Starling's one-button explanation: "Get a heads-up when Riley wants to make plans".
   - Its Continue leads straight to the system alert (ADR 0013 decision 3: no close, no "Not now"; iOS's Don't Allow is the opt-out).
   - The old first-request offer is recorded as made, so it never asks twice.
   - Nothing is asked at launch; reading the authorization state asks nothing.
   - If the owner declined in iOS, You shows a quiet "Notifications are off" line with a Settings button instead of asking again.
10. **Debug-only diagnostics.** The pairing service and the Wi-Fi Aware transport take trace hooks, and Debug builds collect them in You › Developer › Pairing log (shareable). The log names steps, messages, failures, short peer IDs, local device numbers, and `WAError`s, never keys, nonces, or codes. Release builds pass no hook.

## Consequences

- On real phones, pairing needs one owner to pick and both to confirm one code, and survives lost frames, link flaps, and a restart on either phone. Every failure above has a regression test.
- **Pairing a new friend restarts the publisher's listener**, which closes the links it accepted for other friends until their subscribers redial (about a second).
- **A phone with friends in both roles still publishes and subscribes at once**, to different devices. If the reported failure is per device rather than per pair, a later change can use one global role per phone. The device checklist and the pairing log will show it.
- The ceremony now sends a frame per second while it waits, on every link, for at most its 60 s and 120 s windows.
- Threat model input (`docs/requests/P15-G.md`):
  - Before a code is shown, an attacker in range can restart a ceremony with a forged hello or end it with a forged abort for the right attempt. This is denial of service only, as before.
  - Requests are unauthenticated claims; joining one only starts a ceremony.
  - A forged link hello can at most set a Wi-Fi Aware role that stops linking until the next settled hello. This is denial of service only.
- `WAPairedDevice` names "may be intercepted or manipulated by an attacker" (ADR 0102). They label phones and seed a suggestion; they never become a nickname without the owner's Done.

## Sources

- Issue #95 (Oliver's device test, 2026-10-02)
- Apple Developer Forums: thread 811828 (simultaneous publish and subscribe, FB21527009), 787570 (suspension, idle collection), 837110 (pairings persist, PIN once), 794271 (`NWError.wifiAware` to `WAError`), 838513 (BSD Sockets), 807134 (pairing that hangs after the PIN, no root cause)
- Connecting paired devices: https://developer.apple.com/documentation/wifiaware/connecting-paired-devices
- Building peer-to-peer apps (publisher and subscriber in separate roles): https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps
- `WAPairedDevice.name`: https://developer.apple.com/documentation/wifiaware/wapaireddevice/name
- iOS 27 SDK in Xcode 27.0: `WiFiAware.swiftinterface` (`WAPublisherListener.Devices.selected(_:)`, `WASubscriberBrowser.Devices.selected(_:)`, `NWError.wifiAware`)
- `UNNotificationSettings.authorizationStatus`: https://developer.apple.com/documentation/usernotifications/unnotificationsettings/authorizationstatus
- `UIApplication.openNotificationSettingsURLString`: https://developer.apple.com/documentation/uikit/uiapplication/opennotificationsettingsurlstring
- Noise revision 34, section 11.4 (resending a transport message unchanged): https://noiseprotocol.org/noise.html
- ADRs 0003, 0013, 0100, 0101, 0102, 0110, 0111, 0145, 0202
