# ADR 0110: Wi-Fi Aware transport over TCP, with symmetric roles

- Status: Proposed (lane E2), 2026-09-30
- Owner: E2. Wi-Fi Aware transport

## Context

- Wi-Fi Aware roles are asymmetric. A publisher "acts as a server that allows incoming connections"; a subscriber "makes outgoing connections." An app may "simultaneously publish and subscribe the same services," but "can only publish a given service at most once per device" (Adopting Wi-Fi Aware).
- The Swift API plugs into the Network framework: `NetworkListener(for: .wifiAware(.connecting(to: service, from: .allPairedDevices)))` publishes, `NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))` subscribes, and each result is a `WAEndpoint` for `NetworkConnection` (Building peer-to-peer apps; iOS 27 SDK `WiFiAware.swiftinterface`).
- A `WAEndpoint` names a `WAPairedDevice` (a `UInt64` ID local to this phone, plus names). It carries no per-launch instance name, so LocalP2P's `DialRule`, which compares random Bonjour service names, has nothing to compare (ADR 0004).
- **QUIC or TCP.** TN3213 says "If you're not sure which reliable protocol to use, choose QUIC," and that Wi-Fi Aware plus QUIC "is not supported prior to iOS 27" (r. 175046087). iOS 27 is our minimum (ADR 0001), so QUIC is allowed. But QUIC always runs TLS, and TLS needs identities we do not have (ADR 0003). `WAConnection.deriveSharedSecret` (iOS 26.4) can derive a TLS-PSK secret from the pairing, yet Network framework TLS-PSK "doesn't work with QUIC, it doesn't support TLS 1.3, and it only works with the older Network framework API" (TN3213). The other route, one embedded identity with trust checks disabled, gives QUIC "without any meaningful security" (TN3213).
- ADR 0003 puts authentication and encryption in the message layer. Wi-Fi Aware already encrypts the link between OS-paired devices, which binds devices, not Starling identities.
- The macOS 27 SDK ships a `WiFiAware` module, but every symbol in it is `@available(macOS, unavailable)` and `@available(macCatalyst, unavailable)`. `#if canImport(WiFiAware)` is therefore true on macOS, where `swift test` runs.

## Decision

1. **TCP with TLV framing**, identical to LocalP2P: `TLV(type: UInt8.self, length: UInt16.self) { TCP() }`, the same message types (1 hello, 2 frame), and the `LinkHello` from `StarlingLocalP2P`. Each link needs one ordered stream of frames of at most 60 KiB, which TCP gives without TLS identities, and TN3213 notes TCP makes listener management easier. QUIC is revisited if we need several streams or datagrams on one link (for example v2 photo swap), or if device tests show a TCP problem.
2. **Tuning** (TN3213, "Overriding protocol defaults"): TCP keepalive after 5 seconds idle, 3 probes 2 seconds apart, and a 10 second retransmit drop time, so a friend who walks away is noticed in about 10 seconds instead of never. Performance mode `bulk`, Apple's recommendation "for almost all use cases."
3. **Symmetric roles.** Every phone publishes and subscribes `_starling-link._tcp` for all paired devices (ADR 0111). `LinkTable` keeps at most one link per peer and per paired device:
   - A hello teaches us which `PeerID` sits behind a paired device. Once known, the side with the greater `PeerID` dials at once and the other waits `DialRule.fallbackDelay` (3 seconds). This is `DialRule` applied to the two IDs' hex strings, and it agrees with `LinkArbiter`, which keeps the greater side's outgoing link.
   - Before the first hello with a device, both sides dial. The link `LinkArbiter` does not prefer is held **provisional**: no sends, no `peerAvailable`. It becomes active after the same 3 seconds, or as soon as the peer sends on it (proof the peer treats it as active). If the preferred link arrives first, the provisional one closes with nothing lost. ADR 0004 dropped dial-both-and-arbitrate for LocalP2P because frames on the losing link were lost; holding the loser unused avoids that.
   - A second link in the same direction from the same peer replaces the first, because it means the peer redialed (for example after an app restart) and the old link is probably dead.
   - Frames are delivered only from the current link for a peer.
4. **Reconnect.** A dropped link or failed dial is redialed with LocalP2P's `RetryPolicy` (1, 2, 4, 8, 16 seconds) while the device stays discovered. After that the transport waits until the device disappears from and returns to discovery, which also resets the budget. A failed browse or listen restarts with backoff capped at 30 seconds. The browse also restarts when the set of paired devices changes; the listener does not, because restarting it would close the links it accepted, and our own browser dials a newly paired friend anyway.
5. **Testability.** All Wi-Fi Aware calls sit behind the package-level `AwareRadio` protocol. `WiFiAwareRadio` is compiled only under `#if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)`. The transport itself, the link table, and the pairing list model build on macOS and are tested against an in-memory radio that models per-phone device IDs, range, one-sided discovery, and dropped connections.

## Consequences

- On first contact both phones dial, so one extra connection opens and closes. Later reconnects open one.
- With one-sided discovery, the first frame waits up to 3 seconds on first contact (the grace period). Once roles are known, and the side that should dial cannot see us, it waits up to 6 seconds (the fallback wait, then the grace period).
- A frame can still be lost if a preferred link arrives more than 3 seconds after a provisional one was activated, and it replaces it. The `Transport` contract allows loss; negotiation already tolerates it.
- **Threat model input for lane E1:** the `PeerID` in a hello is an unauthenticated claim. An OS-paired device can claim a friend's `PeerID` and displace that friend's link (denial of service). The secure channel rejects its frames, but cannot stop the displacement. Only devices the owner paired in person can try this.
- Keepalives cost a little battery while links are idle. Revisit after device tests.
- Both transports share `LinkMessageType` from `StarlingLocalP2P`. (Revised 2026-09-30: the enum was internal at first and this target kept a copy, `AwareMessageType`, until `docs/requests/E2.md` request 1 made it package-visible.)
- Radio behavior runs only on devices; `docs/checklists/phase-1-E2.md` covers it.

## Sources

- Adopting Wi-Fi Aware: https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware
- Building peer-to-peer apps (sample): https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps
- `WAPublisherListener.Devices.userSpecifiedDevices` ("Will throw an error if used with a NetworkListener"): https://developer.apple.com/documentation/wifiaware/wapublisherlistener/devices/userspecifieddevices
- TN3213, "Moving from Multipeer Connectivity to Network framework": https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- iOS 27 and macOS 27 SDK interfaces in Xcode 27.0 (27A266a): `WiFiAware.swiftinterface`, `Network.swiftinterface`
- ADR 0001, ADR 0003, ADR 0004
