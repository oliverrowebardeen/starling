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
