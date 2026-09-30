# ADR 0121: Where Down? uses the model, and how code keeps it inside the limits

- Status: Proposed
- Date: 2026-09-30
- Owner: F. Negotiation

## Context

- The Phase 0 bench measured the model accepting proposals that broke hard limits in every baseline case. Marking the conflicts in the prompt did not help. Listing broken items first cut violations to 2 of 8, but not to zero (`docs/research/model-budget.md`, finding 3).
- A call takes about 1 to 3 s on a Mac, and phones are slower (finding 2). Fuzzy matching is the model's best job (finding 6).
- ARCHITECTURE rule 6: hard limits are checked in code before and after every model call, with `ConstraintSet.violations(of:timeZone:)` as the single implementation.
- Brief 2.4: the model must earn its place. A Down plan has three issues (time, activity, budget), and only one of them (activity) is really fuzzy.

## Decision

1. **Time and budget use no model at all.** Time comes from the PSI intersection. Budget is the lower of the two caps, answered as a private query. Plain logic does both.
2. **Activity uses one `match` call, on the answering phone only**, and only when its owner has liked activities. Before the call, avoided keywords are removed from the candidates, so the model never sees them. After the call, code keeps only pairs whose `wanted` is a liked keyword and whose `offered` is a real candidate, adds exact matches the model missed, and drops anything avoided.
3. **`decide` runs only when code has built more than one compliant option.** In v1 that happens in one case: a compliant offer with no activity, received by an owner who has a liked activity. The options are "accept as is" and "counter with my favorite activity added," both already checked. A `counter` the model returns is used only if it equals one of those options. An `accept` is used as is. A `reject`, anything else, or an error means accept as offered.
4. **Offers the peer sends that break a limit are never shown to the model.** Code repairs them (budget to the cap, avoided activities dropped, time shortened from its end) or rejects them.
5. **A final gate before every `Outbox.send`** re-checks each outbound value against the owner's limits: plans in `propose`, `counter`, and `accept`, and values in `query` and `answer`. An answer is checked against the issue it names (`Answer.issue`, Core v1.1). A plan must also have the Down shape (exactly one time slot; optional non-empty activity; optional budget amount) and fall inside the intent's own free slots. A refusal ends the conversation silently and increments a diagnostic counter, which the tests require to stay at zero.
6. **A failing model never blocks a match.** `match` errors fall back to exact matching, and `decide` errors fall back to accepting.

Budget per match: at most one `match` call (the responder answers each issue once, so extra queries from a peer buy nothing), plus at most one `decide` call per round in the rare case of item 3. In the common case that is one call, about 1 to 3 s on a Mac.

## Consequences

- Zero hard-limit violations can reach the Outbox whatever the model says. The tests use a hostile scripted model (avoided and invented keywords, a counter that breaks every limit) and check the wire.
- The model's influence is small by design. If device runs show `match` quality is poor on the weaker iOS 27 model, the fallback (exact matching) still works, just with fewer matches.
- A budget in a different currency from the cap is a `currencyMismatch` violation (Core v1.1, from lane F's request), so the one hard-limit check covers it, and a repair replaces it with the owner's cap.
- Owner `DisclosureRule`s are enforced by the policy layer, not here. A `never` rule on activity or budget makes the Outbox refuse the query, and that conversation ends. Leaving withheld issues out of the Down exchange altogether is a Phase 2 improvement.

## Sources

- `docs/research/model-budget.md`, findings 2, 3, and 6.
- ARCHITECTURE.md section 2, rules 6 and 7; ADR 0009 (task-level `AgentModel`).
- Brief section 2.4.
