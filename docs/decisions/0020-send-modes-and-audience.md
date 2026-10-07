# ADR 0020: Send modes and audience: Ask quietly, Invite, and undetectable exclusion

- Status: Accepted (Oliver, 2026-10-01)
- Date: 2026-10-01
- Owner: Orchestrator
- Amends: ADR 0010 (envelope version), ADR 0011 (Compose)

## Context

On 2026-10-01 Oliver asked for two changes to the shared Compose step and the message envelope:

- **Send modes.** "Ask quietly" uses mutual reveal; "Invite" means recipients see the request directly.
- **Audience.** "Everyone except…", saved private groups, and per-friend standing rules. Exclusion must be undetectable.

Asked about the open points, Oliver chose:

- Ask quietly only for skills built on mutual reveal, which today is Down for… alone.
- Standing rules govern the audience only.
- Both changes go in now as Core v2.1.

Core v2 (c07c036) differs:

- `Audience` is all friends, close friends, or picked.
- Down for… is always mutual reveal, and the other skills always invite.
- Envelope version 1 has no mode.
- Envelopes decode with `decodeIfPresent`, and decoding ignores unknown keys. A version 1 build would therefore read a mode field as absent, and could show a quiet ask openly.

## Decision

1. **`SendMode`** (StarlingCore): `askQuietly` (wire `ask_quietly`) or `invite`.
   - Ask quietly: the friend sees nothing unless they are up for it too. "If nobody's up for it, nobody sees you asked."
   - Invite: the friend's agent shows the request as a card.
2. **Skills declare their modes.** `SkillDescriptor.sendModes` lists them, and the first is the default.
   - The list must be non-empty with no repeats.
   - `askQuietly` is allowed only when the building block is `mutualReveal`.
   - Down for… declares `[askQuietly, invite]`. Find a time, Pick a place, and Swap photos declare `[invite]`.
   - Compose shows the choice only for a skill with two modes.
3. **Compose records the mode.** `SkillIntent.mode` is required. `ParsedIntent.mode` is optional: the model may read "quietly" from the owner's words, as a chip the owner can change.
4. **Envelope version 2 carries the mode, and older builds fail closed.**
   - `Envelope.mode` is present exactly when `skill` is.
   - `EnvelopeCodec.supportedVersions` becomes `[0, 2]`. Version 1 never shipped beyond development builds, and it is dropped so that no build that cannot honor a quiet ask ever accepts one.
   - Version 0 frames from Phase 1 builds still decode.
   - `Outbox.send` gains `mode:`. An invitee echoes the mode it received on every reply.
5. **A service enforces its modes on receipt.** An envelope whose mode is not in the skill's `sendModes` is ignored like any unknown request. In particular, a quiet ask never becomes a card.
6. **Audience.** `Audience` adds two cases:
   - `everyoneExcept([PeerID])`.
   - `group(GroupID)`: one of the owner's saved private groups. A `FriendGroup` has a name of 1 to 32 characters with no control characters, and a set of members.
7. **Standing rules, per friend, audience only.** `FriendRule` is one of:
   - `alwaysInclude`
   - `neverInclude`
   - `quietOnly`: ask this friend only quietly, so they are never shown a direct invite.

   Each friend has at most one rule.
8. **One resolver.** `Audience.resolve(mode:friends:book:canRun:)` (StarlingCore) turns an audience into participants. `AudienceBook` holds close friends, groups, and rules. Every surface uses it: Compose, the model's parsed audience, and chains. The rules:
   - **Picked friends are exactly the friends picked.** An explicit choice made now beats any standing rule.
   - **Broad audiences** are all friends, close friends, everyone except, and a group. Each starts from its set, then:
     - adds `alwaysInclude` friends, unless they were explicitly excepted;
     - removes `neverInclude` friends;
     - removes `quietOnly` friends when the mode is `invite`.
   - **Then it keeps only friends whose card supports the skill,** in the order the friends list gives.
   - An unknown group resolves to nobody.
9. **Exclusion is undetectable.** A friend left out by an exception, a group, or a rule must not be able to tell from anything Starling sends. Concretely:
   1. **No traffic per request** to anyone outside the participants. Cards come from link-level `hello`, never from a compose-time exchange.
   2. **Symmetry in mutual reveal.** A quiet ask from someone outside the participants of your own matching request gets exactly the response a friend who is not up for it gets, in shape and timing. Lane B tests this.
   3. **Chains stay inside the plan.** A chained request goes only to attendees of the parent plan, so `chainedFrom` never names a conversation the recipient was not in. Lane E enforces this, and lane F tests it.
   4. **Rosters and counts name only participants.** `people` and `party_size` values list or count only people actually asked.
   5. **The owner's lists stay on the phone.** Groups, exceptions, and rules never leave it, and no `MessageBody` can carry them.
   6. **Stated limit.** Starling cannot stop a participant from telling someone, and with Invite and people set to Share, participants see who else was asked.

## Consequences

- Down for… gains an Invite flow: the friend's agent shows a card instead of matching silently.
- Every skill service passes a mode on send and checks it on receipt.
- Lanes rebuilding on v2.1: A (Compose mode toggle, audience picker, groups, friend rules), B (Invite flow, symmetry, model parsing), C, D, and E (declare modes; E keeps chains inside the plan), F (exclusion, fail-closed mode, version 1 rejected).
- Wire format changes: `EnvelopeCodecTests.wireFormatIsFrozen` moves to version 2.

## Sources

- Oliver's request and answers in conversation, 2026-10-01
- Brief 2.6 (silence by default) and the mutual reveal building block (brief section 4)
- ADRs 0010, 0011, 0012, 0017; `Packages/StarlingCore/Sources/StarlingCore/Messages.swift` and `SkillService.swift`
