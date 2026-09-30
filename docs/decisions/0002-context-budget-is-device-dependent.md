# ADR 0002: Budget model context at runtime, design for 4096

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator (implemented by the Agent lane)

## Context

The brief says the on-device context window "is 4096 tokens." That is no longer a constant:

- TN3193 still says "a context window of 4096 tokens per LanguageModelSession," shared by instructions, prompts, tool definitions, `Generable` schemas, and responses.
- WWDC26-241 shows `print(SystemLanguageModel().contextSize) // 8192` and says the token APIs let you "adapt your app to the hardware it's running on."
- iOS 27 has two on-device models: AFM 3 Core (3B dense) and AFM 3 Core Advanced (20B sparse), the latter only on "our most capable Apple silicon systems." Apple does not document which one `SystemLanguageModel` uses on an 8 GB phone, or what its `contextSize` is.
- PCC offers 32,000 tokens but needs a managed entitlement and a network connection (ADR 0001, verification report).

## Decision

1. `AgentModel` reports its context size at runtime (`ModelDescriptor.contextSize`), read from `contextSize`. Nothing in StarlingKit hard-codes 4096 or 8192.
2. Every negotiation schema and prompt is designed to fit a **4096-token floor** with a safety margin: a single negotiation round (instructions + schema + history summary + response) targets at most 2048 tokens, so it works on the weakest model with room for a second attempt.
3. Each negotiation round runs in a **fresh session** with a compact, typed summary of prior rounds, rather than a growing transcript. This follows TN3193's advice to split work across sessions and keeps round cost flat.
4. The Phase 0 spike records, per device: model availability, `contextSize`, input and output tokens per round, and latency. Results go in `docs/research/model-budget.md`.

## Consequences

- Stronger devices get headroom, not different behavior. The weaker model's quality becomes the bar, which the spike must measure.
- If the spike shows 4096 is too tight for multi-party rounds, the fallbacks are, in order: fewer issues per round, smaller schemas (TN3193 guidance), then PCC with explicit consent (brief 3.7).

## Sources

- TN3193: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- WWDC26-241, "What's new in the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/241/
- `tokenCount(for:)` (iOS 26.4+): https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/tokencount(for:)
- Apple Foundation Models, third generation: https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models
