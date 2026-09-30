# ADR 0006: One SwiftPM package per lane

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator

## Context

Lanes work in parallel worktrees and must only touch directories they own. A single root `Package.swift` listing every target would be edited by every lane and conflict constantly.

## Decision

1. Each directory under `Packages/` is its own SwiftPM package with its own `Package.swift`, owned by one lane. Dependencies between packages are local path dependencies (`.package(path: "../StarlingCore")`).
2. `StarlingCore` depends on nothing but Foundation. Every other package may depend on `StarlingCore`. Dependencies between non-core packages go through the Orchestrator.
3. Manifests use `swift-tools-version: 6.2`, which defaults to the Swift 6 language mode and complete strict concurrency checking. Platforms: `.iOS("27.0")` and `.macOS(.v26)` (ADR 0001).
4. `StarlingCore` ships a second library product, `StarlingFakes`, with deterministic fakes (scripted `AgentModel`, static availability, the insecure PSI stub). Every lane tests against it.
5. Warnings fail CI through `-Xswiftc -warnings-as-errors` on the command line, not in manifests, so local iteration stays quick.
6. `Tools/test-all.sh` runs `swift test` in every package. It is the local test command and what CI runs.

## Consequences

- A lane that needs a change in `StarlingCore` files a request in `docs/requests/<lane>.md` rather than editing it.
- Opening the repo in Xcode shows each package separately; the generated app project references all of them.
- Adding a package means one directory and one line in `Tools/test-all.sh` and `App/project.yml`, both Orchestrator-owned.

## Sources

- Swift Package Manager manifest API: https://developer.apple.com/documentation/packagedescription
- Swift 6 language mode and strict concurrency: https://www.swift.org/documentation/concurrency/
