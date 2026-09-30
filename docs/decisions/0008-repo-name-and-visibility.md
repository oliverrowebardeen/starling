# ADR 0008: Repo name `starling-ios`, private for now

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator (visibility decided by the owner)

## Context

Brief open question 8 lists two "Starling" collisions: an ETHGlobal P2P agent swarm project and a "Starling Agent" VS Code extension. Phase 0 found a third that is closer in domain: `starling-protocol/starling`, an Apache-2.0 protocol for anonymous ad hoc routing over Bluetooth Low Energy between smartphones, last updated May 2024.

## Decision

- Repository: `github.com/oliverrowebardeen/starling-ios`. The suffix separates it from the protocol and agent projects above while keeping the product name.
- Swift module names keep the `Starling` prefix (`StarlingCore`, `StarlingTransport`, ...). They are namespaced by the package, so no collision at build time.
- Visibility: **private**, at the owner's request (2026-09-29). Flip to public for Phase 3 open-source readiness.

## Consequences

- When the repo goes public, the README should say plainly that Starling is unrelated to the BLE routing protocol of the same name.
- Private repos consume GitHub Actions minutes (ADR 0007).

## Sources

- https://github.com/starling-protocol/starling
