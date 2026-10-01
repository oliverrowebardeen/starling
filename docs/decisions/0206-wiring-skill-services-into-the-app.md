# ADR 0206: Wiring the skill lanes' services into the app

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-A (Shell and IA)

## Context

Lanes C (Find a time), D (Pick a place), and E (chaining, audit, Swap photos) merged with requests for the shell: `docs/requests/P15-C.md`, `P15-D.md`, and `P15-E.md`. Each request says what to build and call. A few choices about how are the shell's, and are recorded here.

## Decision

1. **A skill whose flag is off runs no service.** `AppModel` drops the service of every skill not in the build's `SkillFlags`, so a friend's message can never reach it, even though the agent card already leaves it out. Swap photos is built (P15-E 4.8) and stays off this way until its flag turns on.
2. **Services read the owner's choices live.** Find a time asks, each time, whether it is on, whether to use the calendar, and the standing rules (P15-C request 2). `OwnerChoices` answers from the settings and rules in memory, which change before they are saved, so turning a skill off or choosing Just ask me takes effect at once. Before settings load, it answers off, Just ask me, and no rules.
3. **One EventKit store and one location access per app.** Each permission sheet asks through the same object the skill reads from, and only after Continue (ADR 0013 decision 3). Debug builds use the real calendar and location alerts; only photos stays simulated while Swap photos is off.
4. **What left your phone is journaled on disk.** Lane E's `EgressRecorder` is the Outbox observer, fanned out with lane G's audit log, over `FileEgressJournal` (`egress-journal.json`): each change is written before it returns, and an unreadable file or failed write throws, so the send stops. The coordinator is the `EgressSink` and returns only once the record is saved. At launch the order is: load the interactions, finish `recover()`, then restore the services, so no service can schedule a send before recovery (privacy review of PR #73). Until recovery finishes, every audit reads as incomplete, and every caller of startup waits for the same startup task. After that, completeness is live, not a snapshot: each send is marked pending in observable app state in `willSend`, before the transport sees it, and cleared only once its record is durably on the interaction, so a send the transport took and then failed keeps its plan's audit incomplete for the rest of the launch (focused review of PR #73). Plan detail says it cannot confirm a conversation that is still pending, and shows no Kept list at all when the journal was unreadable (P15-E 4.1).
5. **After-plan-ends links start while the app is open.** `PlanEndScheduler` runs from launch and is checked again on foreground. The coordinator confirms each decision with `ScheduledChain.isCurrent` against the stored link in the same main-actor step, and a start goes through its single writer and is flushed before the service hears of it (ADR 0011 amendment 13). The local notification at the next plan end is deferred until Swap photos is on, since nothing can opt in before then.
6. **Retirements are retried at launch and on foreground** for any service that keeps them (Swap photos), through a small `RetriesRetirements` protocol the app conforms lane E's service to.
7. **Local state for ADR 0011 amendments 16 and 17 lives in the plan notes file** (ADR 0204), never sent. Cards the owner passed stay hidden there until their skill reports `ownerPassed`, so a relaunch does not bring them back. A quiet ask becomes one initiator interaction per friend, each in its own conversation, started separately; the coordinator gives them a local group ID, recorded before any starts, and Home shows siblings still in progress as one request while each match gets its own card.

## Consequences

- A skill lane's service is added in one place per build (`LiveServices`, `DebugHarness`), and its descriptor comes from its package, never a copy.
- Turning on Swap photos needs only its flag, its picker in Needs you (P15-E 4.9), and the plan-end notification.

## Sources

- `docs/requests/P15-C.md` items 1 to 3, `P15-D.md`, `P15-E.md` section 4
- ADR 0011 amendment 13, ADR 0013 decision 3 and amendment 6, ADR 0021 decision 4, ADR 0222, ADR 0240 to 0242
- Apple, "Accessing the event store" (EventKit, checked 2026-10-01): "On iOS 17 and later, to access a person's calendar events or reminders, you need to include descriptions for" `NSCalendarsWriteOnlyAccessUsageDescription` or `NSCalendarsFullAccessUsageDescription`, https://developer.apple.com/documentation/eventkit/accessing-the-event-store
