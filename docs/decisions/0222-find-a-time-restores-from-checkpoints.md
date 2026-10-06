# ADR 0222: Find a time resumes from its own checkpoints

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-01
- Owner: P15-C, Find a time

## Context

`SkillService.restore(_:)` is called once at launch with the skill's live interactions, "including any pending question or proposal. The service rebuilds what it can, continuing revisions from the stored ones; one it cannot resume it reports as failed or expired" (Core v2).

An `Interaction` holds the lifecycle: state, history, the current proposal, the pending question, and the revision and consent watermarks. It does not hold what only the service knows: the times offered, which friends have answered and with what, the envelope IDs a confirmation must name, or what this phone told the starter works. Without those, a starter that restarts while collecting answers, which can take hours when friends have no calendar, could only report failure.

Core has no place for per-skill state, and changing `Interaction` waits on the Orchestrator.

## Decision

1. **Checkpoints, owned by the skill.** The service saves each live conversation as an opaque `FindATimeCheckpoint` to a `FindATimeCheckpointStore` after every change, through one serial queue, and removes it when the conversation ends.
   - `InMemoryFindATimeCheckpoints` is the default and the test double.
   - `FileFindATimeCheckpoints` writes one JSON file per interaction, atomically and on iOS with complete file protection. The app passes it a directory such as Application Support.
   - A checkpoint holds candidate times, friends' answers, peer IDs, and message IDs. It never holds anything read from a calendar beyond which times are free.
2. **The store's record wins for the lifecycle.** On restore, the stored `Interaction` replaces the checkpoint's copy, so revisions and watermarks continue from what the coordinator saved. The checkpoint supplies the rest.
3. **Crash windows.** The checkpoint can be ahead of the store when the app dies between the two writes. Restore resumes only from evidence:
   - **Acceptances.** An acceptance, the owner's or this phone's, resumes only when the stored proposal has the checkpoint's revision and terms, and the store has the owner's "That works". A newer proposal in the checkpoint is shown again for a fresh "That works"; an acceptance never moves to terms the owner did not see (review of PR #53).
   - **Plans.** The starter's checkpoint says planned only after every confirmation has left; one restored while confirming finishes the remaining confirmations through Outbox, with a fresh sheet if the policy asks, and becomes a plan only when they leave. A friend's plan needs the starter's confirmation, which it asks for again by resending its acceptance.
   - A question that never reached the store is asked again.
4. **The answer budget and endings live in the ledger.** Answered candidates and retired conversations are in the app's `ConversationLedger` (ADR 0021), persistent and fail-closed, not in checkpoints, so no restart refills a budget or reopens a conversation.
5. **Endings are retired again on restore.** `restore(_:)` also receives interactions that ended in the last 24 hours (ADR 0011, amendment 15) and retires each again, in case the app quit before its retirement was recorded.
6. **What cannot resume.** A starter that restarted while reading the calendar (the range was not saved), and any live interaction without a checkpoint, are reported failed. A plan already made stands.
7. **Consent sheets do not survive.** The coordinator closes any request still open at launch with `consentCancelled` before `restore(_:)` (ADR 0011, amendment 15). The service resends the step it interrupted, which opens a fresh sheet if the policy still asks.

## Consequences

- Restarts resume in every phase the tests cover: an invitee's open question, a starter collecting answers, a starter after "That works", a friend after "That works" whose confirmation was lost, revisions after a restart, and the three crash windows.
- Friends' answers live on the phone at rest until the interaction ends. File protection covers them when the phone is locked.
- If Core later adds per-skill state to `Interaction` (requested), the checkpoint store can move into the coordinator's storage without changing the restore rules.

## Sources

- `Packages/StarlingCore/Sources/StarlingCore/SkillService.swift` (`restore(_:)`) and `Interaction.swift`
- ADR 0011, amendment 10 (content travels with its event; restore rebuilds cards from the store)
- `Data.WritingOptions.completeFileProtection`: https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotection
