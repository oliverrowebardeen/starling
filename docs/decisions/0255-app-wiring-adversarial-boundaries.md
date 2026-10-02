# ADR 0255: Test adversarial boundaries through the installed app coordinator

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-F

## Context

PR #73 merged the app wiring at `b1bc840`. The earlier F service adapters applied
Core events in a fixture. They could not establish the behavior of Compose,
permission and consent sheets, the app's serialized writer, or its disk journal
recovery. Issue #49 requires those integration cases before PR #50 leaves draft.

## Decision

1. Construct the actual AppModel with all four real services, its single Outbox,
   policy, consent coordinator, lifecycle coordinator, chain scheduler, and
   EgressRecorder. Use FileInteractionStore, FileConversationLedger,
   FileSentSequenceStore, FileEgressJournal, FileDownForRequestStore,
   FileFindATimeCheckpoints, and the actual settings, rules, cards, and notes
   files in a separate temporary directory for each phone.
2. Use authenticated Simulation for identity and peer inputs. Simulation's sole
   Inbox accepts every envelope. Its behavior relay forwards ordinary messages
   into the app stream; the fixture forwards the latest accepted hello per peer
   because Simulation handles hellos itself. A borrowed transport leaves the
   Simulation-owned channel alive while AppModel and every disk store reopen.
   This is app/store replacement, not a process or radio crash measurement.
3. Inject ScriptedSkillModel and ScriptedAgentModel, fake calendar permission,
   and fake Maps/location boundaries. The permission adapters and permission
   gate are real. Find a time's test search window covers the whole day so the
   Mac's current hour cannot invalidate the fixture. No real-model claim is
   made and no device is required.
4. Drive Compose, Continue, consent approvals, owner answers, settings changes,
   chain selection, and restart through app APIs. Verify quiet request splitting,
   member interaction attribution, group Invite, exclusion precedence, saved
   groups, ambiguous names, required-topic explanations, and unchanged agent
   cards under Never. Exercise calendar and location denial to a completed plan.
   Ask the actual proposal-text adapter to describe a hostile venue and inspect
   the model facts for containment.
5. Check chain recipients after a group edit and after capability/privacy
   changes. Drive the installed scheduler with a saved opt-in from before the
   plan ended. With photos enabled only for the test, a cancelled pick sends
   nothing; count 3 waits for the actual consent sheet. The normal flag drops
   that service before any peer message reaches it.
6. Reopen pending consent and journal state from disk. An abandoned consent ID
   cannot approve the fresh sheet a restored service may legitimately request.
   Malformed ledger, journal, rules, and settings files fail closed. A stricter
   Never choice stops an already-journaled send before transport and survives
   reopening. Inject late service events through the actual coordinator to
   check ended records and artifacts stay unchanged.
7. Keep new failures as narrow issue-linked assertions, with passing controls:
   #79 is clean withdrawal before failed retirement. Preserve #76's
   separate final-resend reproduction. These are findings, not passing claims.
   PR #78 preserves the journal's interaction ID at `f42cbe1`; assert that ID
   before recovery. PR #83 at `dd830bf` delivers that association through the
   app relay. Both recovery variants now use ordinary assertions for #80.
   PR #85 at `dd62ad6` reaches consent and observer waits with cancellation;
   #81's two app variants also use ordinary assertions. A retired in-flight
   send now throws CancellationError, while a new send still sees conversationRetired.

## Consequences and limits

The test graph executes the merged feature package and services. The iOS-only
LiveServices/DebugHarness factories are source-reviewed and compiled by the
local gate; this host fixture does not execute their Keychain, EventKit, Maps,
notifications, or system picker UI. Down for runs in Debug on InsecurePSIStub
only; Release intentionally has no service until a private PSI provider exists
(ADR 0206 decision 8). Swap photos remains flagged off in normal builds.

Existing native app suites also run in Tools/test-all.sh: startup recovery,
consent queuing and deferred progress, audience/settings recovery races, stale
draft parsing, scheduler claims, and durable storage errors. Their focused
checks complement this authenticated integration graph. Timing and delivery
limits from ADR 0254 still apply. Oliver's numbered checklist retains device
and accessibility checks; real-model measurements remain opt-in.

## Sources

- ADRs 0011 amendments 13 to 17, 0013, 0019, 0020, 0021, 0200 to 0206,
  0210, 0240 to 0242, and 0250 to 0254.
- `App/Features/Sources/StarlingFeatures/AppModel.swift`,
  `LifecycleCoordinator.swift`, `ComposerModel.swift`, `ConsentCoordinator.swift`,
  `FileEgressJournal.swift`, and `FileDownForRequestStore.swift` at `b1bc840`.
- `App/Sources/Composition/LiveServices.swift` and `DebugServices.swift` at
  `b1bc840`; their services use the same Outbox and ConversationLedger.
- `Packages/StarlingCore/Sources/StarlingCore/Outbox.swift` and
  `Packages/StarlingChaining/Sources/StarlingChaining/EgressRecorder.swift` at
  `f42cbe1`.
- [Integration matrix](https://github.com/oliverrowebardeen/starling-ios/issues/49),
  [withdrawal](https://github.com/oliverrowebardeen/starling-ios/issues/79),
  [member audit](https://github.com/oliverrowebardeen/starling-ios/issues/80), and
  [cancellation](https://github.com/oliverrowebardeen/starling-ios/issues/81).
