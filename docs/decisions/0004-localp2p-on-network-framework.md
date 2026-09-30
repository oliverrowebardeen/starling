# ADR 0004: LocalP2P on the Network framework Swift API

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator (implemented by the Transport lane)

## Context

- Multipeer Connectivity is deprecated in Xcode 27; Apple says to migrate to Network framework (TN3213). Confirmed in the framework's DocC deprecation summary.
- iOS 26 added a structured-concurrency Swift API: `NetworkListener`, `NetworkBrowser`, `NetworkConnection`, with built-in type-length-value framing (`TLV`). TN3213 is written against it.
- Peer-to-peer Wi-Fi (AWDL) is off by default and enabled with `peerToPeerIncluded(true)` on the listener, browser, and connection parameters.
- QUIC always needs TLS identities (ADR 0003), and Wi-Fi Aware plus QUIC needs iOS 27.
- Stormo (MIT) is a QUIC-based MPC replacement, published July 2026 with one star.

## Decision

1. LocalP2P uses `NetworkListener` advertising a Bonjour service (`_starling._tcp`) and `NetworkBrowser` discovering it, both with peer-to-peer Wi-Fi enabled.
2. Phase 0 uses **TCP with Network framework TLV framing** (`TLV(type: UInt8.self, length: UInt16.self) { TCP() }`). The 16-bit length caps any frame at 64 KiB inside the framer, so a hostile peer cannot make us buffer an arbitrarily large "frame" before our own checks run. TCP avoids the TLS identity problem while ADR 0003 is pending, and TN3213 notes it makes listener management simpler.
3. Topology is fully connected with TN3213's deduplication rule: when two connections exist between a pair, the peer with the greater `PeerID` keeps its outgoing connection.
4. The Bonjour service name is a random per-launch value, not the device name or a persistent ID, following TN3213 "Design for privacy." The `PeerID` travels in the first frame on the connection, not in the TXT record.
5. Stormo is a reading reference, not a dependency.
6. QUIC is revisited when identities exist (Phase 1), mainly for the Wi-Fi Aware transport.

## Consequences

- The LocalP2P code only runs on real devices or between Macs; unit tests cover the framing and dedup logic, and the Loopback transport covers everything above the wire.
- Needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_starling._tcp`) in the app's Info.plist.
- Apple warns that peer-to-peer Wi-Fi can degrade network performance; browsing stops once a group is connected.

## Sources

- TN3213: https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- Multipeer Connectivity (deprecated): https://developer.apple.com/documentation/multipeerconnectivity
- WWDC25-250, "Use structured concurrency with Network framework": https://developer.apple.com/videos/play/wwdc2025/250/
- Stormo: https://github.com/security-union/Stormo
