# Architecture decision records

One short ADR per major decision, with primary sources. Any lane may propose one; decisions that change a frozen interface or contradict the brief need the owner's agreement before they move from Proposed to Accepted.

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-minimum-ios-27-and-xcode-27.md) | Minimum iOS 27, built with Xcode 27 | Accepted |
| [0002](0002-context-budget-is-device-dependent.md) | Budget model context at runtime, design for 4096 | Accepted |
| [0003](0003-message-layer-security.md) | Authenticate and encrypt at the message layer | Accepted |
| [0004](0004-localp2p-on-network-framework.md) | LocalP2P on the Network framework Swift API | Accepted |
| [0005](0005-xcodegen-for-the-app-project.md) | Generate the app project with XcodeGen | Accepted |
| [0006](0006-one-swiftpm-package-per-lane.md) | One SwiftPM package per lane | Accepted |
| [0007](0007-ci-on-the-xcode-27-runner.md) | CI on the GitHub `xcode-27` runner | Accepted |
| [0008](0008-repo-name-and-visibility.md) | Repo name `starling-ios`, private for now | Accepted |
| [0009](0009-task-level-agent-model-interface.md) | Task-level `AgentModel` interface | Accepted |
| [0010](0010-skills-platform.md) | Starling is a platform of skills | Accepted |
| [0011](0011-one-lifecycle-and-interactions.md) | One lifecycle for every skill, recorded as Interactions | Accepted |
| [0012](0012-artifacts-and-chaining.md) | Skills chain through typed artifacts, with consent per link | Accepted |
| [0013](0013-just-in-time-permissions.md) | Permissions belong to skills and are requested just in time | Accepted |
| [0014](0014-global-privacy-topics.md) | Global privacy topics: Share, Ask me, Never | Accepted (amended by 0019) |
| [0015](0015-information-architecture.md) | Home, New, Friends, You | Accepted |
| [0016](0016-model-in-the-core-loop.md) | The model works in the core loop | Accepted |
| [0017](0017-copy-reads-as-plans-with-friends.md) | Copy reads as plans with friends, not a dating app | Accepted |
| [0018](0018-hand-offs.md) | Hand-offs to Calendar, Messages, Maps, and Siri | Accepted (Muse and Dots open) |
| [0019](0019-never-stays-on-the-phone.md) | Never keeps a value on the phone, and every topic has the same control | Accepted (amends 0014) |
| [0020](0020-send-modes-and-audience.md) | Send modes and audience: Ask quietly, Invite, and undetectable exclusion | Accepted (amends 0010, 0011) |
| [0100](0100-noise-secure-channel-implementation.md) | Noise secure channel implementation | Proposed |
| [0101](0101-pairing-ceremony.md) | Pairing ceremony: Noise XX plus a committed 6-digit code | Proposed |
| [0102](0102-pairing-bootstrap-wifi-aware-pin-vs-qr.md) | Pairing bootstrap: Wi-Fi Aware PIN first, no QR or tap fallback yet | Proposed (needs the owner's agreement) |
| [0110](0110-wifi-aware-transport-tcp-with-symmetric-roles.md) | Wi-Fi Aware transport over TCP, with symmetric roles | Proposed |
| [0111](0111-wifi-aware-services-entitlement-and-pairing.md) | Wi-Fi Aware services, entitlement, and pairing views | Proposed |
| [0120](0120-down-negotiation-protocol.md) | Down? negotiation protocol | Proposed |
| [0121](0121-down-model-use-and-hard-limits.md) | Where Down? uses the model, and how code keeps it inside the limits | Proposed |
| [0130](0130-deterministic-disclosure-and-consent.md) | Deterministic disclosure and explicit consent | Proposed |
| [0131](0131-core-v11-policy-integration.md) | Use Core v1.1 egress context and audit callbacks | Proposed |
| [0140](0140-app-composition-and-release-without-fakes.md) | App composition, and Release builds without StarlingFakes | Proposed |
| [0141](0141-mandatory-rules-review-and-intent-merge.md) | Mandatory review of interpreted rules, and merging rules into Down intents | Proposed |
| [0142](0142-consent-notification-and-permission-ux.md) | Consent sheet, match notifications, and permission prompts | Proposed |
| [0143](0143-wifi-aware-link-test-before-the-secure-channel.md) | Wi-Fi Aware in the app before the secure channel | Proposed |
| [0144](0144-down-wiring-and-the-simulated-friend.md) | Wiring lane F's Down, and a simulated friend until the secure channel | Proposed |
| [0150](0150-adversarial-test-method.md) | Reproducible adversarial tests and paired injection measurements | Accepted |
| [0151](0151-down-policy-integration-tests.md) | Exercise Down and policy together over Loopback | Accepted |
| [0160](0160-measure-model-quality-with-labeled-sets.md) | Measure model quality with labeled sets, a held-out set, and Evaluations | Proposed |
| [0161](0161-ground-interpretation-in-the-owners-words.md) | Ground interpreted rules in the owner's words | Proposed |
| [0162](0162-runtime-schemas-for-match-and-decide.md) | Build match and decide schemas at runtime, and enforce limits in them | Proposed |
| [0170](0170-app-icon-from-an-icon-composer-bundle.md) | App icon from an Icon Composer bundle, wired through XcodeGen | Proposed |
| [0171](0171-icon-group-shadow-at-20-percent.md) | App icon group shadow at 20 percent | Proposed |
| [0172](0172-status-mark-drawn-live-with-even-odd.md) | Status mark drawn live with an even-odd knockout, in its own package | Proposed |

## Template

```markdown
# ADR NNNN: Title

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD
- Owner: lane or Orchestrator

## Context
What forces the decision. Cite sources.

## Decision
What we will do.

## Consequences
What gets easier, what gets harder, what we will revisit.

## Sources
Primary sources first.
```
