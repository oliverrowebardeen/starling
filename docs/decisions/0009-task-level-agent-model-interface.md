# ADR 0009: Task-level `AgentModel` interface

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator

## Context

`StarlingCore` must define `AgentModel` so every lane can test against a deterministic fake (brief Sections 4 and 7). Two shapes were considered:

1. **Generic generation**: `generate<T>(prompt, as: T.Type)`, mirroring `LanguageModelSession.respond(to:generating:)`. This needs `T: Generable`, which would pull `FoundationModels` into `StarlingCore`, and would let any lane build prompts from arbitrary strings, including text a peer sent.
2. **Task level**: `AgentModel` exposes the few jobs where the model earns its place (brief 2.4): interpret the owner's own words into constraints, match fuzzy tags, and choose a negotiation move. Inputs and outputs are `StarlingCore` value types.

## Decision

Use the task-level shape. `StarlingCore` defines `AgentModel` with typed methods and no dependency on `FoundationModels`. `StarlingAgent` implements it with `@Generable` mirror types that stay internal to that package, and owns every prompt. `StarlingFakes` provides a scripted implementation.

## Consequences

- Prompt-injection surface is fixed in one place: the only peer-originated data the model sees is typed and bounded (tags of limited length and character set, time slots, amounts). No free text from a peer reaches a prompt (brief 3.5).
- Fakes are trivial, and negotiation logic tests are deterministic.
- Adding a new model task changes `StarlingCore`, so it goes through the Orchestrator. That is deliberate friction.
- Evaluations (iOS 27) run against `StarlingAgent`'s concrete implementation, not the protocol.

## Sources

- TN3193 on `Generable` token cost: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- WWDC26-339 on the `LanguageModel` provider protocol: https://developer.apple.com/videos/play/wwdc2026/339/
