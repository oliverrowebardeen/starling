# ADR 0222: Find a time resumes from its own checkpoints

- Status: Proposed
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
3. **Crash windows.** The checkpoint can be ahead of the store when the app dies between the two writes:
   - A proposal card that never reached the store is shown again.
   - A question that never reached the store is asked again.
   - A plan confirmed on the wire but not in the store is recorded.
4. **What cannot resume.** A starter that restarted while reading the calendar (the range was not saved), and any live interaction without a checkpoint, are reported failed. A plan already made stands.
5. **Consent sheets do not survive.** The service's copy treats any consent request still open at the restart as given, and resends the step it interrupted, which opens a fresh sheet if the policy still asks. The coordinator's record keeps the dead request open; clearing it is requested in `docs/requests/P15-C.md`.

## Consequences

- Restarts resume in every phase the tests cover: an invitee's open question, a starter collecting answers, a starter after "That works", a friend after "That works" whose confirmation was lost, revisions after a restart, and the three crash windows.
- Friends' answers live on the phone at rest until the interaction ends. File protection covers them when the phone is locked.
- If Core later adds per-skill state to `Interaction` (requested), the checkpoint store can move into the coordinator's storage without changing the restore rules.

## Sources

- `Packages/StarlingCore/Sources/StarlingCore/SkillService.swift` (`restore(_:)`) and `Interaction.swift`
- ADR 0011, amendment 10 (content travels with its event; restore rebuilds cards from the store)
- `Data.WritingOptions.completeFileProtection`: https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotection
