# ADR 0019: Never keeps a value on the phone, and every topic has the same control

- Status: Accepted (Oliver, 2026-10-01)
- Date: 2026-10-01
- Owner: Orchestrator
- Amends: ADR 0014 (decisions 1, 4, and 5)

## Context

On 2026-10-01 Oliver asked for two changes to the privacy topics:

- Every topic gets the same Share / Ask me / Never control: budget, place, diet, photos, interests, and calendar details. Time and activity stay always shared as the overlap.
- "Never" means the value never leaves the device. The agent still uses it locally and answers yes or no on candidates. The control itself says so.
- Defaults are privacy-protective:

  | Topic | Default |
  |---|---|
  | Budget | Never |
  | Exact location | Ask me |
  | Calendar details | Never |
  | Diet | Ask me |
  | Photos | Ask me |
  | Interests | Share |

Asked about the open points, Oliver chose:

- Location is a separate topic from place. Place is the venue options a skill sends, and location is where you are.
- Per-friend standing rules govern the audience only (ADR 0020). Topics stay global.

Core v2 (c07c036) already has topics, but differs:

- No location or calendar details topics.
- Every topic except time and activity defaults to Ask me.
- Never blocks any skill that lists the topic in `topicsRequired`. For example, Place set to Never blocks Pick a place, even though Pick a place could still answer from the owner's location without sending it.

The protocol already has the yes/no answer: `query` asks "which of these candidates work for you?" and `answer.acceptable` returns the subset.

## Decision

1. **Topics.** Two topics are added:
   - `location`: where the owner is, as coordinates or a distance. Its issue key is `location` (new).
   - `calendarDetails`: event titles, places, notes, and attendees from the owner's calendar. Its issue key is `calendar_details` (new).

   `place` now means only the venue options a skill sends. The full list, in the order You shows it: time, activity, place, location, budget, diet, people, photos, interests, calendar details. People is not in Oliver's list, so it keeps its control and its Ask me default.
2. **Defaults.**

   | Topic | Default |
   |---|---|
   | Time, activity | Share |
   | Budget | Never |
   | Calendar details | Never |
   | Interests | Share |
   | Every other topic | Ask me |

   Stored choices win over defaults. A Phase 1 rule migrates as before (lane A).
3. **Never keeps the value on the phone, not out of use.**
   - The policy still denies any envelope that carries a value for a Never topic.
   - The agent may use the value locally to judge candidates, for example a place's price against the budget, or a slot against calendar details.
4. **Yes/no answers are allowed under every choice.** An `answer` whose `acceptable` value is a subset of the candidates of the query it answers discloses only which of the friend's own options work. It carries no value of the owner's.
   - The service passes that query in `OutboundContext.answering`.
   - The policy then allows the answer without a sheet to an on-device agent, whatever the topic's choice. A peer whose model is not on its device still gets a sheet (App Review 5.1.2(i), ADR 0014 decision 3).
   - An answer that is not a subset is judged by its topic as before.
5. **A no must look like any other no.** A rejection caused by a Never value uses `Rejection.Reason.noOverlap`, never `.policy`, so a friend cannot tell that a Never setting was behind it.
6. **Yes/no still teaches something, so it is bounded and stated.**
   - A friend who proposes $10, $20, and $30 places learns which side of each the budget falls. To bound that, a service answers at most `ProtocolLimits.maxCandidatesAnsweredPerIssue` (16) candidates per issue per conversation, and lane F tests it.
   - The copy does not overclaim (decision 8).
7. **`topicsRequired` means values that must leave.** It now lists only topics whose own values a skill has to send to run at all:
   - Swap photos needs photos.
   - Pick a place needs place, to send venue options.

   Topics a skill only uses locally go in `topicsUsed` alone and never block it. `blockingTopics(in:)` and `SkillAvailability.blockedByPrivacy` are unchanged in code. ADR 0014 decision 5 now applies only to values that must leave.
8. **The control explains itself.** Each choice shows one line on the control (lane A owns the final copy):
   - Share: "Sent without asking to friends whose agent runs on their phone. Anyone else still needs your OK."
   - Ask me: "You see and approve exactly what is sent, every time. Your agent can still say whether a friend's option works."
   - Never: "Stays on this phone. Your agent uses it to say yes or no to a friend's options, so friends can learn whether an option works for you."
9. **Calendar details have no Share use yet.** Find a time sends only free and busy times, as the time overlap. In Phase 1.5 no skill sends calendar details, so You shows that topic's Share and Ask me as "Not used by any skill yet" until a skill does.

## Consequences

- Budget, diet, and location rarely block anything. Pick a place and Find a time keep working with them set to Never, judging candidates on the phone.
- The policy gains one rule (decision 4). It keys on trusted local context, not on anything a peer sends, so a peer cannot make an answer look like yes/no.
- Lanes update their descriptors' `topicsRequired`, and lane E's What left your phone lists the two new topics.

## Sources

- Oliver's request and answers in conversation, 2026-10-01
- ADR 0014; `Packages/StarlingCore/Sources/StarlingCore/PrivacyTopics.swift`; `Messages.swift` (`Query`, `Answer`, `Rejection`)
- App Review Guidelines 5.1.2(i): https://developer.apple.com/app-store/review/guidelines/
