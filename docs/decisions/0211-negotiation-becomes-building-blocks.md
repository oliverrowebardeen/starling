# ADR 0211: StarlingNegotiation becomes shared building blocks

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-B. Down for... skill and the model

## Context

Phase 1 put the whole Down feature in `StarlingNegotiation`: `DownNegotiator` (the `DownService`), its profile, and its PSI token set. Phase 1.5 moves features into skill packages under `Packages/Skills/` (ADR 0010), and the lane plan leaves it to lane P15-B whether Phase 1 Down moves out or the package becomes shared building blocks.

Today's dependents of `DownNegotiator`: the app (`App/`, lane P15-A) and the simulator's Down integration tests (`Tools/Simulator/`, the Orchestrator and lane P15-F). Neither is P15-B's to edit, and both keep working only while `DownNegotiator` and Core's Down facade exist.

## Decision

1. **`StarlingNegotiation` is the building blocks package** (brief 2.7: aggregation, mutual reveal, private query, bargaining, exchange). Skills depend on it; it depends on no skill.
2. **Its first shared block is `SlotTokenSet`**: mutual reveal over free half-hours, with a namespace per skill so one skill's tokens never intersect another's. Down for... uses `down_for/v1`. Phase 1's `DownTokenSet` is now a thin wrapper in the `down/v1` namespace, with a test pinning its bytes, so Phase 1 builds still find shared time with each other.
3. **Down for... lives in `Packages/Skills/DownFor/`.** Its profile, planner, and service are skill code, not building blocks; they move to `StarlingNegotiation` only if a second skill needs them.
4. **`DownNegotiator` stays, unchanged, until the app runs Down for....** When lane A wires `DownForService` and the simulator's Down tests move to it, P15-B removes `DownNegotiator`, `DownProfile`, `DownConversation`, and `DownConfiguration` from this package, and the Orchestrator removes Core's Down facade (`DownService`, `DownIntent`, `DownLevel`, `DownMatch`, `DownEvent`, `ScriptedDownService`). The request is in `docs/requests/P15-B.md`.

## Consequences

- Nothing that builds today breaks, and the removal is one reviewable step once nothing calls Phase 1 Down.
- Until then the repo has two Down implementations. Only `DownForService` gets new work; `DownNegotiator` gets fixes only if a Phase 1 build needs them.
- Find a time (lane P15-C) can use `SlotTokenSet` for its own reveal of free slots without depending on Down for....

## Sources

- Brief section 2.7; ADRs 0006 (one package per lane), 0010 (skills platform), 0120 (Down protocol).
- `docs/plans/phase-1.5-lane-plan.md`, lane B row.
- `Packages/StarlingNegotiation/Sources/StarlingNegotiation/SlotTokenSet.swift` and `SlotTokenSetTests`.
