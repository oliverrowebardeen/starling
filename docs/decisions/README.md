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
| [0110](0110-wifi-aware-transport-tcp-with-symmetric-roles.md) | Wi-Fi Aware transport over TCP, with symmetric roles | Proposed |
| [0111](0111-wifi-aware-services-entitlement-and-pairing.md) | Wi-Fi Aware services, entitlement, and pairing views | Proposed |
| [0130](0130-deterministic-disclosure-and-consent.md) | Deterministic disclosure and explicit consent | Proposed |
| [0131](0131-core-v11-policy-integration.md) | Use Core v1.1 egress context and audit callbacks | Proposed |
| [0140](0140-app-composition-and-release-without-fakes.md) | App composition, and Release builds without StarlingFakes | Proposed |
| [0141](0141-mandatory-rules-review-and-intent-merge.md) | Mandatory review of interpreted rules, and merging rules into Down intents | Proposed |
| [0142](0142-consent-notification-and-permission-ux.md) | Consent sheet, match notifications, and permission prompts | Proposed |
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
