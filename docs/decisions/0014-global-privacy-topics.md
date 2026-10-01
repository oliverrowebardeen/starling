# ADR 0014: Global privacy topics: Share, Ask me, Never

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

Phase 1.5 section 6 replaces Phase 1's per-intent "Never share X" toggles and "Otherwise" picker with one control per topic, applied across all skills. The topics are time, activity, place, budget, diet, people, photos, and interests, and each has the choice **Share / Ask me / Never** (mockup "You · privacy topics + skills").

- Time and activity are always shared as the overlap, so they have no Never.
- A skill whose required topic is set to Never explains why it cannot run.

Lane G's `DeterministicPolicyEngine` already enforces per-issue `DisclosureRule`s:

- `never` denies the send.
- `askEachTime` needs consent.
- `allowOnDevicePeers` sends without asking, but only to a peer whose agent runs on its device. Any other peer still needs consent.

## Decision

1. **Topics are a layer above issues.** `PrivacyTopic` (StarlingCore) groups issues:

   | Topic | Issues |
   |---|---|
   | time | time |
   | activity | activity, down_level |
   | place | place |
   | budget | budget |
   | diet | diet |
   | people | people, party_size |
   | photos | photos |
   | interests | interests |

   Every issue belongs to exactly one topic, which a test checks. An issue no topic names falls back to the policy default, ask.
2. **Choices expand into the rules the policy already enforces.** `PrivacySettings.disclosureRules` turns each topic's choice into one `DisclosureRule` per issue:
   - Share becomes `allowOnDevicePeers`.
   - Ask me becomes `askEachTime`.
   - Never becomes `never`.

   The policy engine is unchanged, and egress stays decided in one deterministic place.
3. **Share means "without asking, to on-device agents".** A paired peer whose agent runs in the cloud still gets a consent sheet, because App Review 5.1.2(i) requires explicit permission before sharing with third-party AI (brief 3.7). You's footnote says so in one line.
4. **Time and activity refuse Never** in the initializer, in `set(_:for:)`, and on decode. They default to Share; every other topic defaults to Ask me. You shows one line in place of their rows: "Time and activity are always shared as the overlap. Nothing can line up without them."
5. **Required topics block a skill with a reason.** `SkillDescriptor.blockingTopics(in:)` and `SkillAvailability.blockedByPrivacy` let the app say "Pick a place needs Place. You set Place to Never." instead of failing silently.
6. **The card does not reveal privacy choices.** A skill blocked only by privacy stays on the agent card and declines at request time like any pass (ADR 0010).
7. **Rules merge as before.** A skill intent's rules merge with the standing rules, and the most restrictive sharing wins (ADR 0141). Global topics are the standing sharing.

## Consequences

- Phase 1's rules editor sharing rows and the Down review's "Never share" rows are removed. Lane A's You screen replaces them.
- Policy tests stay valid: topic settings arrive as ordinary disclosure rules.
- The people, photos, and interests issue keys are new. Skills that send them must name them in `topicsUsed`, and `SkillDescriptor` validates that every intent slot is covered.

## Sources

- Phase 1.5 prompt, section 6; mockup "You · privacy topics + skills"
- App Review Guidelines 5.1.2(i): https://developer.apple.com/app-store/review/guidelines/
- `Packages/StarlingPolicy/Sources/StarlingPolicy/Policy.swift` (how the three actions are enforced); `Packages/StarlingCore/Sources/StarlingCore/PrivacyTopics.swift` and its tests
