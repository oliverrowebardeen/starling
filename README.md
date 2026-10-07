# Starling

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/brand/starling-logo-knockout-dark.svg"><img src="docs/brand/starling-logo-knockout.svg" width="64" alt="Starling logo: two overlapping rounded rectangles with the overlap cut out"></picture>

Starling is local-first agent-to-agent coordination for iPhone. Each person's phone runs an on-device agent that knows their availability, intent, and preferences. Friends pair in person; after that, when they want to make a plan ("boba tonight with whoever's free", "find a time for dinner this week"), their agents negotiate directly, phone to phone over Wi-Fi Aware, exchanging only typed values such as time slots, keywords, and budgets. Nothing goes through a server, there are no accounts, and each owner decides what leaves their phone.

The repository holds two things, both under Apache-2.0: **StarlingKit**, the Swift packages under `Packages/` (core types, transports, the secure channel, policy, negotiation, and skills), and the **Starling app**, the reference iOS client under `App/`.

## Status

- **A research prototype, shared as is.** It is not under active development. The app runs the skills Down for..., Find a time, Pick a place, and Change the plan on one shared lifecycle, with Swap photos behind a flag.
- **Not on the App Store** or TestFlight.
- **Down for... runs in Debug builds only.** It needs a private set intersection provider, and the only one here is an insecure test stub, which Release builds exclude.
- **Encrypted, not independently audited.** Links use a Noise secure channel with keys pinned at pairing. It has had automated adversarial reviews by AI models, not an independent security audit ([threat model](docs/THREAT_MODEL.md)).

## Privacy by design

- **Typed values only.** Peers exchange bounded, typed values (time slots, keywords, amounts, flags), never free text, and no peer text is placed in a model prompt.
- **Never stays on the phone.** Each privacy topic (time, place, location, budget, people, calendar details, and others) is set to Share, Ask me, or Never; a topic set to Never is not sent under any skill ([ADR 0019](docs/decisions/0019-never-stays-on-the-phone.md)).
- **The owner's taps gate every action.** A deterministic policy, not the model, decides what may leave, and a consent sheet shows exactly which fields will go before they do. A friend's message never starts a skill, asks for a permission, or skips the consent sheet on the receiving phone.
- **An audit of what left.** Each plan has a "What left your phone" view, built from the same records as the consent sheets.

## Requirements

- A Mac on macOS 26.7 or later with Xcode 27 and the iOS 27 SDK.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the app project.
- For Wi-Fi Aware and pairing: two physical iPhones on iOS 27. The Simulator has no Wi-Fi Aware. The on-device model needs Apple Intelligence (iPhone 15 Pro or later); without it the app falls back to editing chips by hand and template sentences.

## Build and test

From a fresh clone.

### Package tests

```sh
Tools/test-all.sh                # every package, warnings as errors (several minutes)
Tools/test-all.sh StarlingCore   # one package
```

No package has a remote dependency, so nothing is downloaded. Tests that need real hardware or services are skipped unless you opt in:

| Variable | Runs | Needs |
|---|---|---|
| `STARLING_MODEL_TESTS=1` | The real on-device model: the agent bench, skill evaluations, and prompt-injection measurements | A Mac with Apple Intelligence on |
| `STARLING_INJECTION_REPORT=<path>` | With the above, saves the injection measurements as JSON | |
| `STARLING_KEYCHAIN_TESTS=1` | The real Keychain for identity keys and pinned friends | Keychain access |
| `STARLING_NETWORK_TESTS=1` | Real LocalP2P networking over Bonjour | Local network access; often blocked in CI and sandboxes |
| `STARLING_MAPKIT_TESTS=1` | A live Apple Maps search | Internet access |

The `StarlingAgentEvaluations` suites also need macOS 27 and report as skipped on macOS 26.

### The app in the Simulator

```sh
xcodegen generate --spec App/project.yml
open App/Starling.xcodeproj      # then run the Starling scheme on a Simulator
```

Or from the command line:

```sh
xcodebuild build -project App/Starling.xcodeproj -scheme Starling \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/app-debug CODE_SIGNING_ALLOWED=NO
```

The generated project is gitignored; regenerate it after pulling. In the Simulator you can use the screens and the Debug build's scripted services (You › Developer), but not Wi-Fi Aware or pairing between phones.

### The app on iPhones

1. Create `App/Config/Local.xcconfig` (gitignored) with your signing team and a bundle identifier prefix you own:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   STARLING_BUNDLE_ID_PREFIX = com.example.yourname
   ```

   The app's identifier becomes `<prefix>.starling`. The default, `com.example.starling`, is meant only for Simulator builds.
2. Enable the **Wi-Fi Aware** capability for that App ID in your Apple Developer account. The app requests `com.apple.developer.wifi-aware` (Publish and Subscribe) ([ADR 0111](docs/decisions/0111-wifi-aware-services-entitlement-and-pairing.md)).
3. Turn on Developer Mode on both iPhones, regenerate the project, and run the Debug build on each.
4. Pair the two phones in person (Friends › Add friend). The numbered device checklists used during development are in [`docs/checklists/`](docs/checklists/).

### Release checks and the gate

```sh
Tools/check-release-no-fakes.sh    # builds Release; fails if test fakes are linked
Tools/check-release-no-debug.sh    # reuses that build; fails if Debug-only screens are present
Tools/local-gate.sh <branch>       # CI's checks on <branch> merged into origin/main, in a throwaway worktree
```

## Repository map

| Path | What it is |
|---|---|
| `Packages/StarlingCore` | Shared protocols and message types, the `Outbox` and `Inbox` choke points, and `StarlingFakes` for tests |
| `Packages/StarlingTransport` | Loopback, LocalP2P (Network framework), and Wi-Fi Aware transports |
| `Packages/StarlingIdentity` | Identity keys, in-person pairing, and the Noise secure channel |
| `Packages/StarlingPolicy` | The deterministic policy and the consent sheet model |
| `Packages/StarlingAgent` | The Foundation Models implementation of `AgentModel` and `SkillModel`; owns every prompt |
| `Packages/StarlingNegotiation` | Negotiation building blocks shared by the skills |
| `Packages/StarlingAvailability` | Calendar busy and free times, stated intent, and asking the owner |
| `Packages/StarlingChaining` | Chaining one skill into the next, per-link consent, and the plan's audit |
| `Packages/StarlingDesign` | The live status mark and the brand palette |
| `Packages/Skills/` | One package per skill: `DownFor`, `FindATime`, `PickAPlace`, `ChangePlan`, `SwapPhotos` |
| `App/` | The SwiftUI app, generated from `App/project.yml`; `App/Features` holds its testable screens and lifecycle coordinator |
| [`Tools/Simulator`](Tools/Simulator/README.md) | Multi-agent simulation over Loopback, and the adversarial test suite |
| [`Tools/Peer`](Tools/Peer/README.md) | A Mac stand-in for a second phone, for the Debug-only Nearby link test |
| `Tools/*.sh` | The test runner, the local gate, and the Release checks |
| `docs/` | Design, decisions, threat model, research, and development records |

## Docs

- [Architecture](docs/ARCHITECTURE.md): how the packages fit and the rules every package keeps.
- [Threat model](docs/THREAT_MODEL.md): what the secure channel and the skills protect, and what they do not.
- [Design](docs/DESIGN.md): the app's screens and copy rules.
- [Decisions](docs/decisions/README.md): 79 ADRs, each with primary sources.
- [Research](docs/research/): verification reports and model measurements.
- [Brief](docs/BRIEF.md): the original product brief, kept as written.

## How this was built

Starling was built by one developer directing several AI coding agents in parallel workstreams, with frozen shared interfaces, decisions recorded as ADRs, adversarial reviews by a separate AI model, and a red team that only wrote tests. [docs/PROCESS.md](docs/PROCESS.md) describes the process, what it caught, and what went wrong, and explains the terms (lanes, the Orchestrator, request files) used in older docs.

## Contributing and security

Starling is not under active development, so issues and pull requests may not get a response. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Apache License 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE). Copyright 2026 The Starling Authors ([AUTHORS](AUTHORS)).

Apple, iPhone, iOS, Siri, Apple Intelligence, and Xcode are trademarks of Apple Inc., registered in the U.S. and other countries and regions. Wi-Fi Aware is a trademark of Wi-Fi Alliance. Starling is not affiliated with or endorsed by Apple Inc. or Wi-Fi Alliance.

Not affiliated with the Starling BLE routing protocol or other projects of the same name.
