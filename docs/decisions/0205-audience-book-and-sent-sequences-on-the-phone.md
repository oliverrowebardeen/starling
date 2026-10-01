# ADR 0205: The audience book, the Ask picker, and sent sequence numbers on the phone

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-A (Shell and IA)

## Context

Core v2.1 (ADRs 0019 and 0020) leaves three things to the shell:

- Persisting the owner's `AudienceBook` (close friends, saved groups, one rule per friend) and using `Audience.resolve` on every surface.
- Compose's mode choice and audience picker.
- Persisting a `SentSequenceStore`, which `Outbox` calls synchronously before each envelope leaves, so a relaunch never reuses a sequence number even if the clock moved back.

## Decision

1. **The audience book lives in the owner's settings file** (`settings.json`, ADR 0200's helper), beside privacy topics and skill switches. It never leaves the phone. A file from before v2.1 moves its close friends into the book. Unpairing a friend removes them from close friends, every group, and the rules.
2. **One resolver.** New computes participants only with `Audience.resolve(mode:friends:book:canRun:)`, for every audience, including the one the model parsed. A friend with no card yet counts as able to run the skill, because the skill's service checks again at start. A chained step's friends are limited to the parent plan's attendees before resolving, so nothing the owner taps can reach anyone outside the plan (ADR 0020 decision 9.3).
3. **The Ask picker** is a menu: All friends, Close friends, each saved group by name, Everyone except…, and Pick friends. Under Everyone except, tapping a friend leaves them out. Groups are made and edited in Friends. Each friend's detail has a rule: like anyone else, always include, never include, or only ask quietly, each explained in one line.
4. **The mode choice** (Ask quietly or Invite) shows only for a skill with both, which is Down for… today, with its default first. The footnote under the button follows the mode. A mode the model parsed becomes the selected choice only if the skill offers it.
5. **Sent sequence numbers** live in `sent-sequences.json`. `FileSentSequenceStore` holds a lock, writes the file before returning from `recordSent`, and updates memory only after the write succeeds, so a number is on disk before the envelope leaves or the send stops. It keeps the 1,024 most recently used conversations. A dropped conversation restarts at the clock in milliseconds, which is above anything sent earlier unless the clock moved back since. An unreadable file is moved aside.

## Consequences

- Every send rewrites the sequence file. At 1,024 conversations that is tens of kilobytes, fine for the few sends a plan takes.
- Exclusion stays undetectable from the shell's side: resolving happens on the phone, cards come only from link-level hellos, and no request goes to anyone outside the resolved participants.

## Sources

- ADRs 0019, 0020, 0200; `Packages/StarlingCore/Sources/StarlingCore/Audience.swift` and `Outbox.swift` (Core v2.1, 753ddcf)
