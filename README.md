# Starling

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/brand/starling-logo-knockout-dark.svg"><img src="docs/brand/starling-logo-knockout.svg" width="64" alt="Starling logo: two overlapping rounded rectangles with the overlap cut out"></picture>

Local-first agent-to-agent coordination for iPhone. Each person's phone runs an on-device agent that knows their availability, intent, and preferences. When friends want to coordinate, their agents negotiate directly and share only what their owners allow.

**Status: Phase 0 (foundations).** Nothing here is private or secure yet. See `docs/ARCHITECTURE.md`, section 6.

Two deliverables in one repo, Apache-2.0:

- **StarlingKit**: Swift packages under `Packages/` (core types, transport, policy, negotiation building blocks).
- **Starling app**: the reference iOS client under `App/`.

## Requirements

- Xcode 27 (iOS 27 SDK) on macOS 26.6 or later, Apple silicon. Packages also build and test with Xcode 26.1+ on macOS 26 for everything that does not need iOS 27 APIs.
- XcodeGen (`brew install xcodegen`) to generate the app project.
- For the app: an iPhone with Apple Intelligence (iPhone 15 Pro or later) on iOS 27.

## Test

```sh
Tools/test-all.sh              # every package, warnings as errors
Tools/test-all.sh StarlingCore # one package
```

## Docs

- `docs/BRIEF.md`: product and plan
- `docs/ARCHITECTURE.md`: how the pieces fit, frozen interfaces
- `docs/decisions/`: ADRs with sources
- `docs/research/`: verification reports
- `AGENTS.md`: rules for coding agents working in lanes

Not affiliated with the Starling BLE routing protocol or other projects of the same name.
