# Phase 0 research verification (brief Sections 3.1 to 3.6)

Verified 2026-09-29 by the Orchestrator. Verdicts: **Confirmed**, **Partly** (true but incomplete or needs a caveat), **Contradicted** (an ADR records the replacement decision), **Unverified** (no primary source found; treat as an assumption).

Primary sources are Apple documentation (read through the DocC JSON behind each page, since the HTML renders client side), WWDC26 session transcripts, Apple Developer Forums answers from Apple staff, and source repositories. Secondary sources are marked as such.

## Summary of what changed

| # | Finding | Effect | ADR |
|---|---------|--------|-----|
| 1 | The on-device context window is no longer a fixed 4096. WWDC26-241 shows `SystemLanguageModel().contextSize` returning 8192, and Apple says to use the token APIs "to adapt your app to the hardware it's running on." TN3193 still says 4096. | Budget against `contextSize` at runtime; design schemas to fit 4096 as the floor. | [0002](../decisions/0002-context-budget-is-device-dependent.md) |
| 2 | Network framework cannot do "QUIC/TLS with pinned raw keys" directly: TLS-PSK does not work with QUIC or TLS 1.3 or the new Swift API, and Apple platforms have no API to create a self-signed identity. | Put authentication and encryption at the message layer (Noise-style, CryptoKit), not in TLS. The relay needs message-layer encryption anyway. | [0003](../decisions/0003-message-layer-security.md) |
| 3 | Wi-Fi Aware plus QUIC is not supported before iOS 27 (TN3213, r. 175046087). | A second, independent reason for the iOS 27 minimum. | [0001](../decisions/0001-minimum-ios-27-and-xcode-27.md) |
| 4 | The host Mac has Xcode 26.1.1 (Swift 6.2.1, iOS 26.1 SDK). Xcode 27 (Swift 6.4, iOS 27 SDK) shipped 2026-09-14 and needs macOS 26.6+ on Apple silicon. | Owner must install Xcode 27. Packages keep a macOS 26 floor so `swift test` runs on macOS 26 hosts. | [0001](../decisions/0001-minimum-ios-27-and-xcode-27.md), [0006](../decisions/0006-one-swiftpm-package-per-lane.md) |
| 5 | A `starling-protocol/starling` repository (BLE ad hoc routing for smartphones, Apache-2.0, dormant since 2024) exists in addition to the collisions the brief lists. | Repo name `starling-ios` still avoids confusion. | [0008](../decisions/0008-repo-name-and-visibility.md) |
| 6 | iroh 1.0 shipped 2026-06-15 with officially supported Swift bindings (iroh-ffi, `IrohLib`). | Answers the brief's open question for Phase 2; no Phase 0 change. | none (Phase 2 lane L) |

## 3.1 Platform

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Apple Intelligence needs iPhone 15 Pro or later. | Confirmed | iOS 27 tiers: iPhone 15 Pro/Pro Max and the iPhone 16 line (8 GB) get Apple Intelligence; iPhone 15/15 Plus and older do not. MacRumors, 2026-09-09 (secondary): https://www.macrumors.com/2026/09/09/which-iphones-support-every-ios-27-feature/ |
| Every Apple Intelligence iPhone runs iOS 27, so an iOS 27 minimum excludes no one who could run the model. | Confirmed, with a caveat | Apple's list: iOS 27 supports iPhone 11 and later, including every Apple Intelligence model through iPhone 18 Pro. https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-27-iphe3fa5df43/ios. Caveat: people still have to update. iOS 27 shipped in mid September 2026, so a friend on iOS 26 is excluded until they update. |
| The iOS 27 minimum unlocks the iOS 27 Foundation Models APIs. | Confirmed | `PrivateCloudComputeLanguageModel` and the `Evaluations` framework are iOS 27.0+ in their DocC metadata. `LanguageModel` protocol and dynamic profiles are introduced in WWDC26-339 and WWDC26-241. |
| Additional reason not in the brief | New | TN3213: "the combination of Wi-Fi Aware and QUIC is not supported prior to iOS 27 and aligned releases (r. 175046087)." https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework |
| Not all Apple Intelligence iPhones get the strongest on-device model in iOS 27. | Confirmed | Apple Machine Learning Research: two on-device models, "AFM 3 Core" (3B dense) and "AFM 3 Core Advanced" (20B sparse, 1 to 4B active), the latter "unlocked by and optimized for our most capable Apple silicon systems." https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models. Press reports put the Advanced tier at 12 GB RAM devices (iPhone 17 Pro, 17 Pro Max, Air). |
| Which model the Foundation Models framework exposes on each tier. | Unverified | Neither the research post nor WWDC26-241 says which model `SystemLanguageModel` resolves to on an 8 GB phone. The Phase 0 spike records `contextSize` and behavior per device. See ADR 0002. |
| Wi-Fi Aware is iOS/iPadOS only (not macOS) and not in the Simulator. | Confirmed | The `com.apple.developer.wifi-aware` entitlement lists iOS 26.0 and iPadOS 26.0 only. The Wi-Fi Aware framework also lists Mac Catalyst 26.0, but the entitlement does not. The sample "Building peer-to-peer apps" says "you can't run this sample in Simulator." https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps |
| Wi-Fi Aware hardware floor (not in brief) | New | iPhone 12 and later, per the WiFiAware framework overview. Every Apple Intelligence iPhone qualifies. |
| iOS-to-Android Wi-Fi Aware is unreliable. | Not checked | Android is out of scope for v1, so this claim does not affect any decision. |

## 3.2 Layers

No external claims to verify. The layer list is the basis for the package layout in ADR 0006 and `docs/ARCHITECTURE.md`.

## 3.3 Transport

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Multipeer Connectivity is deprecated in the iOS 27 SDK. | Confirmed | DocC deprecation summary: "Multipeer Connectivity is deprecated. Migrate any code using this framework to the Network framework." TN3213: "Xcode 27 deprecates the entire Multipeer Connectivity framework." |
| MPC has reported regressions on iOS 26. | Confirmed (forum reports) | https://developer.apple.com/forums/thread/803339 ("Multipeer Connectivity connection is flaky on iOS 26"). Stormo's README also describes MPC peer-to-peer Wi-Fi as broken on iOS 26. |
| TN3213 and the "Building a custom peer-to-peer protocol" sample are the migration references. | Confirmed | Both URLs resolve. TN3213 uses the iOS 26 Swift API (`NetworkListener`, `NetworkBrowser`, `NetworkConnection`). The TicTacToe sample is older (iOS 16, Bonjour + TLS) and uses TLS-PSK, which TN3213 now calls limited. |
| Stormo is a usable reference library. | Partly | Exists, MIT, "QUIC over Network.framework, AWDL-capable," last push 2026-07-31, 1 star. Good to read; too young to depend on. https://github.com/security-union/Stormo |
| LocalP2P = Bonjour + AWDL through Network framework. | Confirmed | TN3213 "Enable peer-to-peer Wi-Fi": peer-to-peer is off by default; opt in with `peerToPeerIncluded(true)` on connection, listener, and browser parameters. Apple warns it can reduce network performance and suggests Wi-Fi Aware where possible. |
| Wi-Fi Aware pairing is mandatory. | Confirmed | Apple DTS in forum thread 791628: "Yes. That's how Wi-Fi Aware works." |
| Pairing goes through DeviceDiscoveryUI. | Partly | Either DeviceDiscoveryUI (`DevicePicker`, `DevicePairingView`) or AccessorySetupKit. The sample uses DeviceDiscoveryUI for iPhone to iPhone. |
| Pairing uses a PIN and appears in Settings > Privacy & Security > Paired Devices. | Unverified by a primary source | Only a secondary source says this (Espressif blog, 2026-08: https://developer.espressif.com/blog/2026/08/wifi-aware-esp-to-iphone/). Phase 1 lane E confirms on device. |
| Wi-Fi Aware needs the entitlement and `WiFiAwareServices`. | Confirmed | Entitlement value is an array containing `Publish` and/or `Subscribe`. `WiFiAwareServices` maps service names (15 chars max, `_name._tcp` or `_name._udp`) to `Publishable` and/or `Subscribable` dictionaries. An invalid name crashes the app. https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware |
| Wi-Fi Aware roles (not in brief) | New | Roles are asymmetric: publisher (listener) and subscriber (outgoing connection). An app may publish and subscribe the same service at once, but may publish a given service only once per device. The Transport implementation has to hide this so the rest of StarlingKit sees symmetric peers. |
| Wi-Fi Aware in the background (not in brief) | New | "Your app may connect to paired Wi-Fi Aware devices whenever it's running, in both foreground and background states." Relevant to Phase 2: this helps only while the app has runtime; it does not wake a suspended app. |
| BLE background advertising: no local name, service UUIDs move to overflow. | Confirmed (verbatim) | `startAdvertising(_:)`: "While your app is in the background, the local name isn't advertised and all service UUIDs are in the overflow area." |

## 3.4 Remote coordination (Phase 2 research; claims checked now)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Foundation Models requests in the background may be throttled or canceled. | Confirmed | Apple engineer in thread 833642: "On iOS, we might limit access to the model on background tasks. We recommend designing your code around the assumption that excessive requests to the model made in the background might be throttled or canceled." |
| A backgrounded app cannot keep listening sockets open; waking needs APNs; APNs needs a server. | Consistent with Apple docs, not re-derived in Phase 0 | Wi-Fi Aware docs above only promise connections while the app is running. Phase 2 lane L owns the detailed check. |
| iroh 1.0 is released; Swift bindings unknown. | Confirmed and answered | iroh 1.0 released 2026-06-15 (https://www.iroh.computer/blog/v1). The team now officially supports Swift bindings through iroh-ffi (`IrohLib` on Swift Package Index), v1.1.0 on 2026-07-16. |

## 3.5 Identity and security

| Claim | Verdict | Evidence |
|-------|---------|----------|
| CryptoKit identity keys stored in the Keychain. | Confirmed as feasible | Standard CryptoKit (Curve25519, P-256, HPKE since iOS 17). No contradiction. |
| Choose between Noise and QUIC/TLS with pinned raw keys. | Contradicted as framed | TN3213: Network framework TLS-PSK "doesn't work with QUIC, it doesn't support TLS 1.3, and it only works with the older Network framework API." Custom identities need a `SecIdentity`, and "Apple platforms have no API to" create one; TN3213 points to swift-certificates. QUIC cannot run without TLS. Raw public keys (RFC 7250) are not offered by the API. See ADR 0003. |
| Bitchat uses Noise with Curve25519. | Confirmed | Bitchat whitepaper: `Noise_XX_25519_ChaChaPoly_SHA256`. https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md |
| Bitchat was criticized for security claims before review. | Confirmed (secondary) | A researcher showed impersonation shortly after the TestFlight release; the project then added an "under development" warning. https://www.supernetworks.org/pages/blog/agentic-insecurity-vibes-on-bitchat |
| Typed messages, deterministic policy layer, threat model first. | Design rules, not factual claims | Adopted as-is in `docs/ARCHITECTURE.md` and the StarlingCore interfaces. |

## 3.6 Model

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Default model is `SystemLanguageModel`. | Confirmed | |
| Context window is 4096 tokens, shared by input and output. | Contradicted for iOS 27 | TN3193 still says "a context window of 4096 tokens per LanguageModelSession" and that all instructions, prompts, schemas, tool definitions, and responses count against it. WWDC26-241 shows `print(model.contextSize) // 8192` and says "You'll want to use these going forward to adapt your app to the hardware it's running on." See ADR 0002. |
| Token APIs `contextSize` and `tokenCount(for:)` are iOS 26.4+. | Partly | `tokenCount(for:)` is iOS 26.4+. DocC marks `contextSize` as iOS 26.0 (back deployed), but WWDC26-241 says both shipped in 26.4. Neither is in the iOS 26.1 SDK installed on this Mac. Newer: `response.usage` reports input, cached, output, and reasoning token counts (WWDC26-241). |
| iOS 27 opens Foundation Models to other providers behind the same session API. | Confirmed | WWDC26-339: providers conform to `LanguageModel` plus a `LanguageModelExecutor`; `LanguageModelSession(model:)` accepts `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `CoreAILanguageModel`, `MLXLanguageModel`. Anthropic and Google publish their own packages. The session also stresses that developers must disclose where a model runs, which supports brief Section 3.7. |
| PCC is free for Small Business Program apps under 2M downloads. | Confirmed, with caveats | WWDC26 iOS guide, verbatim: "fewer than 2 million total first-time App Store downloads ... at no cloud API cost." Caveats: PCC use needs a managed entitlement you must apply for (`PrivateCloudComputeLanguageModel` docs), and developers report the 2M count spans the whole developer account (https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/, secondary). PCC context is 32,000 tokens. |
| Use the Evaluations framework to track negotiation quality. | Confirmed | `Evaluations` is iOS/macOS 27.0+ and Xcode 27.0+: datasets, metrics (pass/fail to model-judge), aggregated summaries, works with any Foundation Models model. Needs Xcode 27, so it lands after the owner installs it. |

## Section 7 checks

| Claim | Verdict | Evidence |
|-------|---------|----------|
| Does Foundation Models run on the host Mac? | Confirmed | On this Mac (M5, 16 GB, macOS 26.7), `SystemLanguageModel.default.availability` returns `available`. A macOS build of the model harness can therefore smoke-test prompts and schemas. macOS 26.7 does not ship the iOS 27 model, so these numbers are not device numbers. |
| Does Foundation Models run in the iOS Simulator? | **No, on this setup** | iOS 26.1 Simulator (Xcode 26.1.1) on the same Mac: `availability` reports `.available`, but every generation fails with a Model Catalog error ("no underlying assets ... for asset set com.apple.modelcatalog"). Model tests therefore run natively on macOS or on devices. Re-check with Xcode 27 and the iOS 27 Simulator. |

## Open questions answered in Phase 0

- **Q5 (does 4096 suffice?):** Answered by the model spike report, `docs/research/model-budget.md`, once the owner runs the harness on device.
- **Q7 (prior art):** see below.
- **Q8 (name collisions):** ADR 0008.

### Prior art (Q7), first pass

| System | What it is | How Starling differs |
|--------|------------|----------------------|
| Rene (Second Enlightenment, 2026-09) | iMessage agent; two users' agents exchange calendar availability and propose a slot, both humans approve. Runs in the cloud via OpenRouter with OAuth access to calendars and mail. https://www.progressiverobot.com/2026/09/16/multiplayer-ai-agent-rene-imessage-calendar-coordination/ (secondary) | Starling's calendar never leaves the device, and no server holds identity or the social graph. |
| Blockit | Cloud agent-to-agent calendar negotiation for work, over email and Slack (brief 2.6). | Personal and family scheduling, on device. |
| "Device-Native Autonomous Agents for Privacy-Preserving Negotiations" (arXiv 2601.00911) | Research system: 500M distilled on-device model, ZK proofs, insurance and B2B price negotiation. No iOS detail, no code. | Starling targets shipping iPhones with Apple's model and friend-scale social coordination. |
| A2A v1.0 | Web-native (HTTP, JSON, SSE) agent protocol. | Starling runs over intermittent local links first; A2A mapping is Phase 3. |
| Bitchat | BLE mesh messenger with Noise; not an agent system. | Borrow the handshake idea and its lessons on premature security claims. |

No existing system found that runs negotiating agents on phones over local peer-to-peer links. A deeper search is still worth doing before the README makes a "first" claim.
